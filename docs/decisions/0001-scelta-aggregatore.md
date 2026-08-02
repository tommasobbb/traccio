# 0001 — Open Banking aggregator: Enable Banking

Status: accepted
Date: 2026-08-01

## Context

Traccio needs read access to Italian bank accounts under PSD2. Reading
accounts is a regulated AIS activity: it requires either an AISP licence or
operating under an aggregator's licence as a "fourth party" — a model Banca
d'Italia has explicitly allowed, provided the account holder gets clear
disclosure and gives specific consent.

The commonly recommended free option, Nordigen / GoCardless Bank Account
Data, is gone: new signups are disabled and the product is winding down.
Any tutorial built on it is obsolete.

Traccio starts as a personal tool with no legal entity (see 0002), so the
provider must allow building on real data before any contract exists.

## Decision

**Enable Banking**, used first in *restricted production* (own accounts,
no contract, no KYB, no cost).

Reasons:
- Sandbox and production access before signing anything; restricted
  production connects real accounts for free.
- Italian coverage documented bank by bank, including per-bank SCA flows.
  Card account access was extended in March 2026 to BPER, Postepay, Fineco,
  Banco BPM/Bibanca and Nexi including YAP.
- Acts as a pass-through: it neither stores nor reuses the data.
- A TPP-as-a-service path exists if Traccio ever obtains its own eIDAS
  certificates.

## Consequences

- **No enrichment.** Enable Banking does not categorize or clean merchant
  data; it relies on external partners. Categorization is entirely ours to
  build. This is the main cost of the choice.
- **Pricing is not public** and is volume-based with a monthly minimum.
  Going public requires a signed contract and KYB, therefore a legal
  entity. Not a problem before M4.
- Provider-specific behaviour is confined to `providers/`; adding a second
  adapter must not require touching services.

## Alternatives considered

- **Salt Edge** — has a Partners API built for companies that do not want an
  AISP licence, and includes categorization. Quote-only, enterprise-paced
  onboarding.
- **Tink (Visa)** — probably the best European coverage plus native
  enrichment, which would solve categorization. Enterprise-gated since the
  Visa acquisition; per-user pricing scales badly for a small product.
- **TrueLayer** — excellent developer experience, but the centre of gravity
  moved to Pay by Bank; data aggregation is no longer the focus.
- **Fabrick (Gruppo Sella)** — authorized by Banca d'Italia, sells "AISP as
  a service" for exactly the fourth-party model, strong Italian coverage,
  has a PFM categorization engine. Not self-serve, aimed at banks and
  structured companies. **The strongest candidate to revisit at M4** if
  Traccio goes public in Italy.
- **Plaid** — Europe is Custom plans only; the free Trial tier is limited to
  new US and Canada teams. Excluded.
- **Direct bank APIs** — requires our own eIDAS certificate, a fixed annual
  cost that exceeds the entire budget of a personal project.

## Revisit when

- M4 is reached and a production contract is needed → re-evaluate Enable
  Banking vs Fabrick vs Salt Edge with real usage data in hand.
- Categorization quality proves unacceptable → consider a dedicated
  enrichment vendor (Tapix, Snowdrop) as a separate layer.
- PSD3/PSR and FIDA come into application; provisional agreement was reached
  in late 2025 with final texts expected during 2026.