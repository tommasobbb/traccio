"""Enable Banking adapter (M1 restricted production).

Concrete :class:`~traccio.providers.base.BankProvider` implementation for Enable
Banking. This package is the anti-corruption boundary for Enable Banking-shaped
data; nothing above ``providers/`` sees it. Read ``docs/openbanking.md`` before
changing anything here — the onboarding procedure, credential handling, and
operational constraints (consent lifetime, background fetch budget, PSU headers)
shape the design.

Implements the full :class:`~traccio.providers.base.BankProvider` contract:
minting the short-lived RS256 bearer JWT from the application private key
(:mod:`.auth`), a thin authenticated HTTP client (:mod:`.client`), the
consent handshake (:mod:`.provider`'s ``start_authorization``/
``complete_authorization``), and account/transaction retrieval
(``list_accounts``/``fetch_transactions``).
"""
