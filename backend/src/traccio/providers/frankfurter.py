"""HTTP client for the frankfurter.dev exchange-rate API (ADR 0021).

frankfurter.dev serves ECB reference rates: free, no API key, historical and
range endpoints, self-hostable. This is a thin wrapper over
:class:`httpx.Client` on the same pattern as
:class:`~traccio.providers.enable_banking.client.EnableBankingClient` — one
request choke point that wraps any failure in :class:`FxRateError` with a
value-free message (never a response body), and a ``transport`` seam so tests
serve responses offline.

Rates are parsed into :class:`~decimal.Decimal` from the JSON number's string
form, so no float ever touches a monetary computation (root ``docs/engineering.md``).

Endpoints used:

- ``GET /{start}..{end}?base={base}&symbols={csv}`` — one rate per ECB
  publication day in the range (weekends/holidays omitted).
- ``GET /latest?base={base}&symbols={csv}`` — the most recent published day.
"""

from datetime import date
from decimal import Decimal, InvalidOperation
from types import TracebackType
from typing import Any, cast

import httpx

DEFAULT_BASE_URL = "https://api.frankfurter.dev/v1"


class FxRateError(Exception):
    """A frankfurter.dev request failed.

    Raised in place of the underlying ``httpx`` exception (whose message could
    carry a response body). The message is stable and value-free; the status
    code is the only detail let through, mirroring
    :class:`~traccio.providers.base.ProviderError`.
    """


class FrankfurterClient:
    """Exchange-rate API client.

    Parameters
    ----------
    base_url : str, optional
        API base URL. Defaults to :data:`DEFAULT_BASE_URL`; the caller passes
        ``Settings.fx_api_base_url``.
    transport : httpx.BaseTransport or None, optional
        Custom transport, used by tests to serve responses offline. Defaults
        to the real network transport.
    """

    def __init__(
        self,
        *,
        base_url: str = DEFAULT_BASE_URL,
        transport: httpx.BaseTransport | None = None,
    ) -> None:
        self._client = httpx.Client(base_url=base_url, transport=transport)

    def _get_json(self, url: str, *, params: dict[str, str]) -> dict[str, Any]:
        """GET ``url`` and return the parsed JSON object, or raise :class:`FxRateError`."""
        try:
            response = self._client.get(url, params=params)
            response.raise_for_status()
        except httpx.HTTPStatusError as exc:
            raise FxRateError(
                f"frankfurter API returned status {exc.response.status_code}"
            ) from exc
        except httpx.HTTPError as exc:
            raise FxRateError("frankfurter API request failed") from exc
        return cast(dict[str, Any], response.json())

    @staticmethod
    def _rates_of(raw: Any) -> dict[str, Decimal]:
        """Parse one ``{"EUR": 1.08, ...}`` object into exact ``Decimal`` values."""
        if not isinstance(raw, dict):
            raise FxRateError("frankfurter API response is malformed")
        out: dict[str, Decimal] = {}
        for code, value in raw.items():
            try:
                out[code] = Decimal(str(value))
            except (InvalidOperation, ValueError) as exc:
                raise FxRateError("frankfurter API returned a non-numeric rate") from exc
        return out

    def rates_in_range(
        self, *, base: str, symbols: list[str], start: date, end: date
    ) -> dict[date, dict[str, Decimal]]:
        """One rate set per ECB publication day in ``[start, end]``.

        Parameters
        ----------
        base : str
            The currency rates convert *into*.
        symbols : list[str]
            The currencies to fetch rates *from* (never includes ``base``).
        start, end : date
            Inclusive range. frankfurter omits days the ECB did not publish.

        Returns
        -------
        dict[date, dict[str, Decimal]]
            Publication date -> {quote currency -> rate}. Empty if the range
            contains no publication day.
        """
        body = self._get_json(
            f"/{start.isoformat()}..{end.isoformat()}",
            params={"base": base, "symbols": ",".join(symbols)},
        )
        raw_rates = body.get("rates")
        if not isinstance(raw_rates, dict):
            raise FxRateError("frankfurter API response is missing 'rates'")
        out: dict[date, dict[str, Decimal]] = {}
        for day_str, day_rates in raw_rates.items():
            try:
                day = date.fromisoformat(day_str)
            except ValueError as exc:
                raise FxRateError("frankfurter API returned a malformed date") from exc
            out[day] = self._rates_of(day_rates)
        return out

    def latest_rates(self, *, base: str, symbols: list[str]) -> tuple[date, dict[str, Decimal]]:
        """The most recently published rate set.

        Returns
        -------
        tuple[date, dict[str, Decimal]]
            The publication date and {quote currency -> rate}.
        """
        body = self._get_json("/latest", params={"base": base, "symbols": ",".join(symbols)})
        day_str = body.get("date")
        if not isinstance(day_str, str):
            raise FxRateError("frankfurter API response is missing 'date'")
        try:
            day = date.fromisoformat(day_str)
        except ValueError as exc:
            raise FxRateError("frankfurter API returned a malformed date") from exc
        return day, self._rates_of(body.get("rates"))

    def close(self) -> None:
        """Close the underlying HTTP connection pool."""
        self._client.close()

    def __enter__(self) -> "FrankfurterClient":
        return self

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc: BaseException | None,
        tb: TracebackType | None,
    ) -> None:
        self.close()
