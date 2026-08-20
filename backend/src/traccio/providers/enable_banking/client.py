"""Authenticated HTTP client for the Enable Banking API.

A thin wrapper over :class:`httpx.Client` that attaches a freshly minted RS256
bearer JWT (:mod:`.auth`) to every request. It holds the connection details and
the application credentials; the layers above ``providers/`` never see it.

Slice 1 exposes a single endpoint, :meth:`EnableBankingClient.list_aspsps`
(``GET /aspsps``), which lists the banks Enable Banking supports for a country.
It requires authentication but returns **no personal data**, so it doubles as an
end-to-end auth smoke test and is genuinely useful later for institution
selection. The consent handshake and account/transaction endpoints — which do
touch personal data and must return domain objects, not raw payloads — land in
later slices.

Data safety (``.claude/rules/data-safety.md``): this module never logs the JWT,
the credentials, or any response body. ``/aspsps`` carries no personal data;
endpoints added later must not surface provider bodies in logs or exceptions.
"""

from types import TracebackType
from typing import Any, cast

import httpx

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
            data). Raw provider shape — this is a provider-internal helper, not
            part of :class:`~traccio.providers.base.BankProvider`.
        """
        response = self._client.get(
            "/aspsps", params={"country": country}, headers=self._auth_header()
        )
        response.raise_for_status()
        body = response.json()
        return cast(list[dict[str, Any]], body["aspsps"])

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
