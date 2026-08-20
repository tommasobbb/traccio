"""The bank provider adapter interface.

``providers/`` is an anti-corruption layer (see ``docs/architecture.md``):
provider-shaped data stops here, and everything above sees only domain objects.
Every adapter implements the same interface — start authorization, complete
authorization, list accounts, fetch transactions — so adding a second provider
never requires touching ``services/``. Nothing above ``providers/`` may branch
on which provider or which bank produced a record; if it needs to, the adapter
failed to normalize.

Each adapter owns three normalization duties, documented per adapter in
``docs/openbanking.md``:

- **Sign convention per account kind.** Whatever the bank sends, a purchase is
  stored negative — card accounts, which many banks invert, included
  (``docs/domain.md``).
- **Stable transaction identity.** Prefer the bank's ``entry_reference``; when
  absent, derive a hash and record the :class:`~traccio.domain.enums.KeyStrategy`.
- **Date semantics.** Distinguish ``booked_at`` (settlement) from ``value_date``
  (balance effect).

This module imports only ``domain`` (the layering rule) and stays free of any
provider SDK, HTTP client, or network dependency. The concrete Enable Banking
adapter, the token-encryption scheme, and the redirect-URL decision are separate
work (see ``tasks/backlog.md`` M1 and ``docs/openbanking.md``); the method
signatures here are intentionally minimal and firm up alongside that adapter.

Data safety (``.claude/rules/data-safety.md``): the DTOs below and the
``credentials`` passed to the fetch methods carry consent/session secrets.
Secret fields are excluded from ``repr`` so an accidental log of a whole
instance cannot leak them, but the rule stands — log identifiers and counts,
never these objects or a provider response body.
"""

from abc import ABC, abstractmethod
from collections.abc import Mapping
from datetime import datetime

from pydantic import BaseModel, ConfigDict, Field

from traccio.domain import Account, ConnectionStatus, Transaction


class AuthorizationStart(BaseModel):
    """The first step of a consent handshake: where to send the user.

    Returned by :meth:`BankProvider.start_authorization`. The client opens
    ``authorization_url`` in the **system browser** (never an in-app WebView —
    bank SCA apps often fail to open from one; see ``docs/openbanking.md``) and,
    once the user completes SCA, the adapter finishes the handshake with
    ``session_reference``.

    Attributes
    ----------
    authorization_url : str
        The bank authorization URL to open in the system browser. Handed to the
        client; it may embed a state token, so it is not written to logs.
    session_reference : str
        Opaque handle pairing this in-progress authorization with the callback.
        Passed back to :meth:`BankProvider.complete_authorization`. Sensitive —
        excluded from ``repr`` and never logged.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    authorization_url: str
    session_reference: str = Field(repr=False)


class AuthorizationResult(BaseModel):
    """The outcome of a completed consent handshake.

    Returned by :meth:`BankProvider.complete_authorization`. ``credentials`` is
    the opaque secret the caller encrypts at rest and stores against the
    :class:`~traccio.domain.models.Connection` (the encryption scheme is a
    separate M1 decision); it is passed back to the fetch methods, decrypted, on
    each sync. ``expires_at`` drives ``Connection.expires_at`` — consent expiry
    is a first-class product concern, not an error case.

    Attributes
    ----------
    credentials : str
        Opaque provider consent/session secret, to be encrypted at rest by the
        caller. Never returned by any endpoint, never logged — excluded from
        ``repr``.
    status : ConnectionStatus
        Resulting consent lifecycle state (typically ``active``).
    expires_at : datetime or None
        Consent expiry (timezone-aware, UTC), or ``None`` when the provider does
        not report one.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    credentials: str = Field(repr=False)
    status: ConnectionStatus
    expires_at: datetime | None = None


class SyncContext(BaseModel):
    """Whether a user is actively waiting on a sync.

    Threaded into the fetch methods so the adapter sets the PSU-present headers
    accordingly. The distinction is not cosmetic: user-present requests are not
    subject to the per-consent background fetch budget, while background ones are
    (``docs/domain.md`` Sync, ``docs/openbanking.md`` operational constraints).

    Attributes
    ----------
    psu_present : bool
        ``True`` when the user triggered the sync and is waiting; ``False`` for
        scheduled background syncs, which must respect the fetch budget.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    psu_present: bool


class BankProvider(ABC):
    """Interface every bank adapter implements.

    Concrete adapters live alongside this module (one per provider). The four
    operations below are the only surface the layers above ``providers/`` see;
    they exchange the provider-agnostic DTOs in this module and the domain
    entities, never provider-shaped payloads. See the module docstring for the
    normalization duties each implementation owns.
    """

    @property
    @abstractmethod
    def name(self) -> str:
        """Stable provider identifier (e.g. ``"enable_banking"``).

        Safe to log to attribute a connection to its provider; it identifies the
        adapter, not any secret or account.
        """

    @abstractmethod
    def start_authorization(self, *, institution: str, redirect_url: str) -> AuthorizationStart:
        """Begin a consent handshake for ``institution``.

        Parameters
        ----------
        institution : str
            Provider-scoped identifier of the bank to authorize.
        redirect_url : str
            Whitelisted URL the bank returns the user to after SCA.

        Returns
        -------
        AuthorizationStart
            The URL to open in the system browser and the reference needed to
            complete the handshake.
        """

    @abstractmethod
    def complete_authorization(
        self, *, session_reference: str, callback_payload: Mapping[str, str]
    ) -> AuthorizationResult:
        """Finish the handshake started by :meth:`start_authorization`.

        Parameters
        ----------
        session_reference : str
            The opaque handle from the matching :class:`AuthorizationStart`.
        callback_payload : Mapping[str, str]
            The parameters the bank returned to ``redirect_url`` (e.g. an
            authorization code). Sensitive — never logged.

        Returns
        -------
        AuthorizationResult
            The consent secret to store encrypted, its lifecycle state, and its
            expiry.
        """

    @abstractmethod
    def list_accounts(self, *, credentials: str, context: SyncContext) -> list[Account]:
        """List the accounts reachable through a consent.

        Parameters
        ----------
        credentials : str
            The decrypted consent secret from a prior :class:`AuthorizationResult`.
        context : SyncContext
            Whether a user is present, to set the PSU headers.

        Returns
        -------
        list[Account]
            Domain accounts. ``identification_hash`` is the adapter's derived
            stable identity, not the provider's account id (which is not stable
            across consents).
        """

    @abstractmethod
    def fetch_transactions(
        self,
        *,
        credentials: str,
        account: Account,
        since: datetime,
        until: datetime | None,
        context: SyncContext,
    ) -> list[Transaction]:
        """Fetch transactions for one account within a date window.

        The initial sync after a new connection is greedy (the ~1h full-history
        window); later syncs are incremental. Either way the adapter returns
        already-normalized domain transactions: sign per account kind, stable
        key with its :class:`~traccio.domain.enums.KeyStrategy`, and
        ``booked_at`` vs ``value_date`` resolved.

        Parameters
        ----------
        credentials : str
            The decrypted consent secret.
        account : Account
            The account to fetch, as returned by :meth:`list_accounts`.
        since : datetime
            Start of the window (timezone-aware, UTC).
        until : datetime or None
            End of the window, or ``None`` for "up to now".
        context : SyncContext
            Whether a user is present, to set the PSU headers.

        Returns
        -------
        list[Transaction]
            Normalized domain transactions.
        """
