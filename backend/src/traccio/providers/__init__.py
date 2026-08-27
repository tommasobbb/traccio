"""External-service adapters (anti-corruption layer); imports only domain.

Bank adapters under ``enable_banking/`` plus the frankfurter.dev rate client
(``frankfurter.py``, ADR 0021): each isolates one external API's HTTP shapes
so the layers above never see a provider-specific payload or exception.
"""
