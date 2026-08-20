"""Authenticated HTTP client for the Enable Banking API.

A thin wrapper over :class:`httpx.Client` that attaches a freshly minted RS256
bearer JWT (:mod:`.auth`) to every request. It holds the connection details and
the application credentials; the layers above ``providers/`` never see it.

This client speaks Enable Banking's HTTP shapes and returns the raw provider
payloads; normalizing them into domain objects is the job of
:class:`~traccio.providers.enable_banking.provider.EnableBankingProvider`, which
composes this client. The endpoints here:

- ``GET /aspsps`` — the supported banks for a country (no personal data; doubles
  as an auth smoke test and feeds institution selection).
- ``POST /auth`` — start a consent handshake; returns the SCA ``url``.
- ``POST /sessions`` — exchange the callback ``code`` for a session; the
  ``session_id`` in the response is the credential used for later data calls.

The account and transaction endpoints — which return domain objects, not raw
payloads — land in a later slice.

Data safety (``.claude/rules/data-safety.md``): this module never logs the JWT,
the credentials, or any response body. ``/auth`` and ``/sessions`` responses
carry secrets (the SCA url embeds ``state``; a session response holds
``session_id`` and account details), so a failed request is wrapped in a
:class:`~traccio.providers.base.ProviderError` with a value-free message rather
than re-raising the provider exception (whose message could carry a body).
"""

from collections.abc import Mapping
from types import TracebackType
from typing import Any, cast

import httpx

from traccio.providers.base import ProviderError
from traccio.providers.enable_banking.auth import mint_bearer_jwt

DEFAULT_BASE_URL = "https://api.enablebanking.com"


class EnableBankingClient:
    """Authenticated Enable Banking API client.

    Parameters
    ----------
    application_id : str
        Enable Banking application ID (the JWT ``kid``; not a secret).
    private_key_pem : str
        The application RSA private key in PEM form. Secret — never logged. Held
        to mint a fresh short-lived JWT per request.
    base_url : str, optional
        API base URL. Defaults to :data:`DEFAULT_BASE_URL`.
    transport : httpx.BaseTransport or None, optional
        Custom transport, used by tests to serve responses offline. Defaults to
        the real network transport.
    """

    def __init__(
        self,
        *,
        application_id: str,
        private_key_pem: str,
        base_url: str = DEFAULT_BASE_URL,
        transport: httpx.BaseTransport | None = None,
    ) -> None:
        self._application_id = application_id
        self._private_key_pem = private_key_pem
        self._client = httpx.Client(base_url=base_url, transport=transport)

    def _auth_header(self) -> dict[str, str]:
        """Return an ``Authorization`` header with a fresh bearer JWT."""
        jwt = mint_bearer_jwt(
            application_id=self._application_id,
            private_key_pem=self._private_key_pem,
        )
        return {"Authorization": f"Bearer {jwt}"}

    def _request_json(
        self,
        method: str,
        url: str,
        *,
        params: Mapping[str, str] | None = None,
        json: Mapping[str, Any] | None = None,
    ) -> Any:
        """Send an authenticated request and return the parsed JSON body.

        A non-2xx status or a transport failure is wrapped in a
        :class:`~traccio.providers.base.ProviderError` with a value-free message;
        the provider exception is chained (``raise ... from``) for debugging but
        its detail never enters the message we raise (data-safety).
        """
        try:
            response = self._client.request(
                method, url, params=params, json=json, headers=self._auth_header()
            )
            response.raise_for_status()
        except httpx.HTTPStatusError as exc:
            raise ProviderError(
                f"Enable Banking API returned status {exc.response.status_code}"
            ) from exc
        except httpx.HTTPError as exc:
            raise ProviderError("Enable Banking API request failed") from exc
        return response.json()

    def list_aspsps(self, country: str) -> list[dict[str, Any]]:
        """List the banks Enable Banking supports in ``country``.

        Parameters
        ----------
        country : str
            ISO 3166-1 alpha-2 country code (e.g. ``"IT"``).

        Returns
        -------
        list[dict]
            The provider's ``aspsps`` entries (institution metadata; no personal
            data). Raw provider shape — normalized by the provider, not here.
        """
        body = self._request_json("GET", "/aspsps", params={"country": country})
        return cast(list[dict[str, Any]], body["aspsps"])

    def start_authorization(
        self,
        *,
        aspsp_name: str,
        aspsp_country: str,
        redirect_url: str,
        state: str,
        access: Mapping[str, Any],
        psu_type: str,
    ) -> dict[str, Any]:
        """Start a consent handshake (``POST /auth``).

        Parameters
        ----------
        aspsp_name, aspsp_country : str
            The bank's Enable Banking identity (``name`` + ISO country).
        redirect_url : str
            Whitelisted callback the bank returns the user to after SCA.
        state : str
            Opaque anti-CSRF token, echoed back in the callback query.
        access : Mapping
            Requested scope, including ``valid_until``.
        psu_type : str
            ``"personal"`` or ``"business"``.

        Returns
        -------
        dict
            Raw provider response, notably ``url`` (the SCA redirect) and
            ``authorization_id``.
        """
        payload = {
            "access": access,
            "aspsp": {"name": aspsp_name, "country": aspsp_country},
            "state": state,
            "redirect_url": redirect_url,
            "psu_type": psu_type,
        }
        return cast(dict[str, Any], self._request_json("POST", "/auth", json=payload))

    def authorize_session(self, *, code: str) -> dict[str, Any]:
        """Exchange a callback ``code`` for a session (``POST /sessions``).

        Parameters
        ----------
        code : str
            The authorization code returned to ``redirect_url`` after SCA.

        Returns
        -------
        dict
            Raw provider response, notably ``session_id`` (the credential),
            ``accounts``, and ``access``.
        """
        return cast(dict[str, Any], self._request_json("POST", "/sessions", json={"code": code}))

    def close(self) -> None:
        """Close the underlying HTTP connection pool."""
        self._client.close()

    def __enter__(self) -> "EnableBankingClient":
        return self

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc: BaseException | None,
        tb: TracebackType | None,
    ) -> None:
        self.close()
