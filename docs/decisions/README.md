# Architecture Decision Records

Each file here records one decision: the context that forced it, what was
chosen, the consequences accepted, and — where relevant — the alternatives
considered and what would change the call. They're written once and rarely
edited; when a decision is reversed, a new ADR supersedes the old one rather
than rewriting it.

Numbers are chronological, not thematic. Copy the format from an existing
one when adding a new entry (see `CONTRIBUTING.md`, "Before you start
something bigger than a one-line fix").

Several entries cite `tasks/backlog.md` or `tasks/ROADMAP.md` as where an
item was tracked before it was resolved. Those are a personal working log,
gitignored and not part of this repository — a fresh clone won't have them;
the citation is provenance, not a link you can follow.

| # | Title |
|---|-------|
| [0001](0001-aggregator-choice.md) | Open Banking aggregator: Enable Banking |
| [0002](0002-personal-first.md) | Ship as a personal tool first, decide about a business later |
| [0003](0003-token-encryption-at-rest.md) | Token encryption at rest: Fernet with an env-var key |
| [0004](0004-reimbursements-derivation.md) | Reimbursements: derived state, stored write-off |
| [0005](0005-categorization-rules.md) | Categorization rules: deterministic string match, specificity ordering, full recompute |
| [0006](0006-consent-lifecycle.md) | Consent lifecycle: derived expiry state, re-auth in place |
| [0007](0007-dashboard-aggregation.md) | Dashboard aggregation: effective_amount only, per-currency, no breakdown |
| [0008](0008-client-design-direction.md) | Client design direction: a light, custom UI instead of stock native |
| [0009](0009-client-navigation-fourth-tab.md) | Client navigation: a fourth "Impostazioni" tab |
| [0010](0010-background-sync-scheduler.md) | Background sync scheduler |
| [0011](0011-psu-headers-behind-a-flag.md) | PSU-present headers: built, tested, deliberately not turned on |
| [0012](0012-reimbursement-participant-attribution.md) | Reimbursement participant attribution |
| [0013](0013-biometric-lock.md) | Biometric lock: iOS-only, `.deviceOwnerAuthentication`, off by default |
| [0014](0014-api-token.md) | A shared bearer token, not real auth, gates the deployed backend |
| [0015](0015-deploy-fly-io.md) | Deploy on Fly.io, not a self-managed VPS |
| [0016](0016-onboarding-gate.md) | Gate the four-tab shell behind onboarding instead of fixing client injection app-wide |
| [0017](0017-semantic-appearance-tokens.md) | Semantic appearance tokens for accounts and categories |
| [0018](0018-two-level-category-hierarchy.md) | A strict two-level category hierarchy |
| [0019](0019-repairing-incomplete-synced-transactions.md) | Repairing already-synced rows with a one-off script, not a relaxed write path |
| [0020](0020-manual-accounts.md) | Manual accounts as bank-less rows, editable by row origin not status |
| [0021](0021-fx-conversion-dashboard.md) | FX conversion in the dashboard: opt-in, additive, ECB rates |
| [0022](0022-funded-payment-pairing.md) | Funded payments: pairing two outflows so a card-funded wallet spend counts once |
| [0023](0023-file-import.md) | File import for feeds Traccio cannot connect to |
| [0024](0024-tracking-start-date.md) | Tracking start date: a reversible per-user floor, not a delete |
| [0025](0025-transfer-detection-scope-and-cost.md) | Transfer detection: bound its scope and its cost |
| [0026](0026-advances-receivables-summary.md) | Advances: a cross-advance receivables summary, name-keyed |
| [0027](0027-event-identity-emoji-and-colour.md) | Event identity: a free-text emoji, a token colour, one update endpoint |
| [0028](0028-event-category-breakdown-and-suggestions.md) | Event: a category breakdown and date-range suggestions |
| [0029](0029-meal-vouchers.md) | Meal vouchers: a voucher-kind account, excluded and reported separately |
| [0030](0030-liquid-glass-chrome.md) | Liquid Glass in the chrome, deployment target raised to 26 |
| [0031](0031-visual-coherence-pass.md) | Visual coherence pass: chrome, sheets, motion applied everywhere |
| [0032](0032-glass-on-raised-cards.md) | Liquid Glass on `.raised` cards |
| [0033](0033-more-tab-and-settings-corner.md) | "Altro" tab and Impostazioni in Panoramica's corner |
| [0034](0034-brand-triad.md) | A brand triad and a rounded type voice |
| [0035](0035-glass-to-chrome-only-and-triad-withdrawn.md) | Glass narrowed to chrome only; the brand triad withdrawn |
| [0036](0036-movimenti-row-actions.md) | Row actions on Movimenti; the Dettaglio narrows |
| [0037](0037-sync-budget-counts-fetches-not-skips.md) | The background sync budget counts fetches, not skips |
| [0038](0038-anticipi-list-inherits-detail-treatment.md) | Anticipi's list screen inherits its own detail screen's treatment |
