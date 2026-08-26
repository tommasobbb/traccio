"""The bank provider adapter interface.

``providers/`` is an anti-corruption layer (see ``docs/architecture.md``):
provider-shaped data stops here, and everything above sees only domain objects.
Every adapter implements the same interface — list institutions, start
authorization, complete authorization, list accounts, fetch transactions — so
adding a second provider never requires touching ``services/``. Nothing above
``providers/`` may branch on which provider or which bank produced a record;
if it needs to, the adapter failed to normalize.

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

from traccio.domain import Account, AccountKind, ConnectionStatus, CurrencyCode, Transaction


class ProviderError(Exception):
    """A bank provider operation failed.

    The provider-agnostic error contract every adapter raises and the layers
    above ``providers/`` catch — so callers never handle provider-specific
    exception types (the anti-corruption rule extends to errors, not just data).

    Messages must be **stable and value-free** (``.claude/rules/data-safety.md``):
    an adapter never re-raises a provider/library exception unchanged, since its
    message may carry a response body; it wraps it with ``raise ... from`` and a
    fixed message, attaching only a non-sensitive identifier when one helps.
    """


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


class ProviderAccount(BaseModel):
    """One account discovered through a consent, in provider-agnostic form.

    Returned by :meth:`BankProvider.list_accounts`. It carries only what the bank
    knows about the account; it deliberately omits ``user_id`` and
    ``connection_id`` (which the adapter cannot know), so the caller composes the
    persisted :class:`~traccio.domain.models.Account` by injecting those — exactly
    as :class:`AuthorizationResult` is turned into a stored ``Connection``.

    ``identification_hash`` is the adapter's derived stable identity, not the
    bank's account id (which is not stable across consents): the raw account
    identifier (IBAN or other) never leaves the adapter, only its hash does.

    Attributes
    ----------
    identification_hash : str
        Derived stable identity used to match the account across consents.
    kind : AccountKind
        ``current``, ``savings``, ``card``, or ``wallet``, normalized from the
        provider's account type.
    currency : str
        The account's own ISO 4217 currency (a wallet may report ``XXX``).
    name : str or None
        Optional display name (the account's product name), for the client only.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    identification_hash: str
    kind: AccountKind
    currency: CurrencyCode
    name: str | None = None


class Institution(BaseModel):
    """One bank a provider supports authorizing, in provider-agnostic form.

    Returned by :meth:`BankProvider.list_institutions` — public institution
    metadata only (no personal or consent data), used to feed
    :class:`~traccio.api.schemas.connections.StartConnectionRequest`'s
    ``institution``/``country`` fields from a picker rather than requiring the
    caller to already know the provider's exact institution name.

    Attributes
    ----------
    name : str
        The provider-scoped institution identifier — pass this straight back
        as ``StartConnectionRequest.institution``.
    country : str
        ISO 3166-1 alpha-2 country the institution is offered in.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    name: str
    country: str


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

    Concrete adapters live alongside this module (one per provider). The five
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
    def start_authorization(
        self, *, institution: str, country: str, redirect_url: str
    ) -> AuthorizationStart:
        """Begin a consent handshake for ``institution``.

        Parameters
        ----------
        institution : str
            Provider-scoped identifier of the bank to authorize.
        country : str
            ISO 3166-1 alpha-2 country of the bank. Open Banking institutions are
            country-scoped, so identity is ``(institution, country)``.
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
    def list_accounts(self, *, credentials: str, context: SyncContext) -> list[ProviderAccount]:
        """List the accounts reachable through a consent.

        Parameters
        ----------
        credentials : str
            The decrypted consent secret from a prior :class:`AuthorizationResult`.
        context : SyncContext
            Whether a user is present, to set the PSU headers.

        Returns
        -------
        list[ProviderAccount]
            Provider-agnostic accounts. The caller injects ``user_id`` and
            ``connection_id`` to build the persisted
            :class:`~traccio.domain.models.Account`. ``identification_hash`` is
            the adapter's derived stable identity, not the provider's account id
            (which is not stable across consents).
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

    @abstractmethod
    def list_institutions(self, *, country: str) -> list[Institution]:
        """List the institutions this provider supports authorizing in ``country``.

        Feeds a client-side picker so the user (and
        :meth:`start_authorization`'s ``institution`` argument) never has to
        already know the provider's exact institution name — the same
        anti-corruption reasoning as every other method here: the caller sees
        only :class:`Institution`, never a provider-shaped payload.

        Parameters
        ----------
        country : str
            ISO 3166-1 alpha-2 country code (e.g. ``"IT"``).

        Returns
        -------
        list[Institution]
            The institutions offered in ``country``, in the provider's own
            order.
        """
