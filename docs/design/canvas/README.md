# Design canvas sources

Sources for the M3 design canvas (four mockup screens: Dashboard,
Transactions, Transaction detail, Accounts). Settled tokens are recorded in
`docs/design/tokens.md` — read that first; it's the file that costs almost
nothing to load. Come here only when you need to look at a screen or edit the
mockups directly.

## What these are

`.dc.html` files authored with an AI-assisted design-canvas tool
(`x-dc` custom element, `{{handlebars}}` template holes, `data-props` tweaks).
`canvas.json` lays out the four artboards on one canvas. They do **not** open
standalone in a browser — each references `./support.js`, which is provided by
the canvas environment, not present here.

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
names) per `.claude/rules/data-safety.md`. Keep it that way in any edit —
these files are published to a viewable page.
