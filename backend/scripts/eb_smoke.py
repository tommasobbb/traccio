"""Enable Banking auth smoke test — list supported banks for a country.

An operational helper, not part of the app or the test suite. It mints an RS256
bearer JWT from the configured application credentials and calls ``GET /aspsps``,
which returns institution metadata only (no personal data — see
``EnableBankingClient.list_aspsps``). Two purposes:

1. **Validate authentication end to end** against the real Enable Banking API —
   a non-error response proves the ``<application-id>.pem`` and application id
   are wired correctly (the live check left pending since the auth slice).
2. **Discover the exact institution ``name``** to pass to ``POST /connections``
   (the ``StartConnectionRequest.institution`` field), e.g. the precise strings
   for Revolut / IsyBank / PayPal.

Run with ``make eb-aspsps COUNTRY=IT`` (needs ``TRACCIO_ENABLE_BANKING_*`` set in
a local ``.env``). Lives under ``scripts/`` — outside ``src/traccio/`` — because
the root ``docs/engineering.md`` reserves the package tree for the layered modules.

Data safety (``docs/engineering.md``): prints only a count and each
bank's ``name`` + ``country`` (public institution metadata). It never prints the
JWT, the private key, the ``.env``, or any raw provider response body.
"""

import argparse
import sys

from traccio.core.config import get_settings
from traccio.providers.base import ProviderError
from traccio.providers.enable_banking.auth import load_private_key_pem
from traccio.providers.enable_banking.client import EnableBankingClient


def main() -> int:
    """List the Enable Banking ASPSPs for a country.

    Returns
    -------
    int
        Process exit code: ``0`` on success, ``1`` on a missing credential or a
        provider error (message kept value-free — no key/JWT/body).
    """
    parser = argparse.ArgumentParser(description="List Enable Banking ASPSPs for a country.")
    parser.add_argument(
        "--country",
        default="IT",
        help="ISO 3166-1 alpha-2 country code (default: IT).",
    )
    args = parser.parse_args()

    settings = get_settings()
    if settings.enable_banking_application_id is None:
        print("TRACCIO_ENABLE_BANKING_APPLICATION_ID is not set", file=sys.stderr)
        return 1
    if settings.enable_banking_private_key_path is None:
        print("TRACCIO_ENABLE_BANKING_PRIVATE_KEY_PATH is not set", file=sys.stderr)
        return 1

    client = EnableBankingClient(
        application_id=settings.enable_banking_application_id,
        private_key_pem=load_private_key_pem(settings.enable_banking_private_key_path),
        base_url=settings.enable_banking_base_url,
    )
    try:
        aspsps = client.list_aspsps(args.country)
    except ProviderError as exc:
        # The message is already value-free (the client wraps any body); print
        # it without the chained transport detail.
        print(f"Enable Banking request failed: {exc}", file=sys.stderr)
        return 1
    finally:
        client.close()

    # Print institution metadata only (name + country) — never a raw body.
    print(f"{len(aspsps)} ASPSPs for {args.country}:")
    for aspsp in sorted(aspsps, key=lambda a: str(a.get("name", ""))):
        print(f"  {aspsp.get('name')}  ({aspsp.get('country')})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
