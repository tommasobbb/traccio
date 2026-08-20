"""Enable Banking adapter (M1 restricted production).

Concrete :class:`~traccio.providers.base.BankProvider` implementation for Enable
Banking. This package is the anti-corruption boundary for Enable Banking-shaped
data; nothing above ``providers/`` sees it. Read ``docs/openbanking.md`` before
changing anything here — the onboarding procedure, credential handling, and
operational constraints (consent lifetime, background fetch budget, PSU headers)
shape the design.

Slice 1 provides only the authentication foundation: minting the short-lived
RS256 bearer JWT from the application private key (:mod:`.auth`) and a thin
authenticated HTTP client (:mod:`.client`). The consent handshake, account and
transaction retrieval land in later slices (see ``tasks/backlog.md`` M1).
"""
