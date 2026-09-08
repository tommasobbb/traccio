# Tone-pass canvas sources

The design canvas for ADR 0008's **2026-09-08 tone revision** ("darle un
tono"). Five artboards on two pages:

- **Sistema** — `Main` (the harmonized data palette, light + dark, with a
  "prima / dopo" per tone), `Typografia` (the designed figure treatment and
  the type scale), `Superfici` (the three elevation levels and the day-group
  container vs. rows floating apart).
- **Schermate** — `Panoramica` and `Movimenti` recomposed for hierarchy.

This is a **separate** published artifact from the M3 canvas one directory up
(`../`, "Traccio App Design") — it has its own `canvas.json`. Settled token
values are in `docs/design/tokens.md`; the ADR records the *why*
(`docs/decisions/0008-client-design-direction.md`, the 2026-09-08 revision).

`.dc.html` mechanics and the re-seed / re-publish workflow are the same as
`../README.md` describes. Every figure here is synthetic
(`.claude/rules/data-safety.md`).
