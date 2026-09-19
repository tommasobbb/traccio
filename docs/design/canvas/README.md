# Design canvas sources

Sources for the design canvas. Two rows of artboards on one canvas:

- **Row 1 — M3, as shipped** (`Main`, `Transactions`, `TransactionDetail`,
  `Accounts`): the four screens ADR 0008 established.
- **Row 2 — Fase B redesign** (`MainV2`, `TransactionsV2`,
  `TransactionsFilters`, `TrackingStart`): proposals from the "Bella e
  affidabile" milestone, to be judged visually before any SwiftUI is written.
  `Accounts` is deliberately not reworked — it's the model the others follow.

Settled tokens are recorded in `docs/design/tokens.md` — read that first; it's
the file that costs almost nothing to load. Come here only when you need to
look at a screen or edit the mockups directly.

## What these are

`.dc.html` files authored with an AI-assisted design-canvas tool
(`x-dc` custom element, `{{handlebars}}` template holes, `data-props` tweaks).
`canvas.json` lays out the eight artboards on one canvas. They do **not** open
standalone in a browser — each references `./support.js`, which is provided by
the canvas environment, not present here. The seeded, publishable payload
(`traccio-app-design.html`, ~2 MB) is a build artifact — regenerate it with
`seed-canvas.mjs`, don't commit it.

## Published copy

The seeded, viewable version is published to a shareable page — see the link
in `docs/decisions/0008-client-design-direction.md`. That's where to look at
the screens without re-seeding anything.

## Re-publishing after an edit

Edit the `.dc.html` files here, then use the `design` skill's `seed-canvas.mjs`
helper to rebuild the payload and republish to the same artifact URL (pass
`url:` so it updates in place rather than creating a new artifact). If you
change any token value, update `docs/design/tokens.md` and
`docs/decisions/0008-client-design-direction.md` in the same change — they are
prose copies of what's authoritative here, not the other way around.

## Data safety

Every figure in these mockups is synthetic (round amounts, invented merchant
names) per `engineering.md`'s data safety section. Keep it that way in any edit —
these files are published to a viewable page.
