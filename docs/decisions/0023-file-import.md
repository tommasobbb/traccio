# 0023 — File import for feeds Traccio cannot connect to

Status: accepted
Date: 2026-08-30

## Context

Some accounts have no Enable Banking connection (Satispay, and others until
they are integrated), so they are invisible to Traccio and every total is
incomplete. ADR 0020 gave the user manual accounts with hand-entered
movements; typing a month of Satispay transactions by hand is not realistic.
Satispay exports a monthly `.xlsx` with a stable per-row id, an Italian
`Data`/`Importo` layout, emoji in the `Tipo`/`Stato` cells, and — because it
holds a balance and meal vouchers in one wallet — an amount split across a
`Disponibilità` column and a `Buoni Pasto` column.

## Decision

**1. A generic import engine; a source's layout is data, not code.** A
`ImportProfile` (`domain/imports/profiles.py`) names the columns *by header
text* (a reordered export still works), the date format and timezone, the
decimal conventions, the fixed currency, an optional id column, an optional
status column, and — for a source that splits an amount — a `SplitRule`.
`SATISPAY` and a bare `GENERIC` (date/amount/description CSV) are the two
profiles; a third source is a new constant, not new parsing code.

**2. Read xlsx and csv from one path.** `services/imports.decode_rows`
sniffs the ZIP magic, reads xlsx with `openpyxl` (`read_only`, `data_only`)
or CSV with the stdlib `csv` (delimiter-sniffed, BOM-tolerant), and yields
`header -> cell` maps. Everything downstream is pure:
`domain/imports/parse.parse_import` classifies each row with no I/O.
`openpyxl` (pure Python, one transitive dep) is the one new package, approved
by the user; `types-openpyxl` is a dev dependency for `mypy --strict`.

**3. Preview, then commit.** `POST /imports/preview` classifies every
movement the file would create — `new`, `already_imported`, or `invalid`
(with a stable reason code) — and writes nothing. `POST /imports/commit`
takes the same body and inserts only the `new` ones. The file travels as
base64 in a JSON body: the client is JSON-only and this avoids a
`python-multipart` dependency. `TRACCIO_IMPORT_MAX_BYTES` (2 MiB) bounds it
→ `413`.

**4. `KeyStrategy.IMPORTED`, keyed by the source's id.** An imported
movement's `stable_key` is `"{profile}:{external_id}"` (the voucher leg gets
a `":voucher"` suffix), so the existing `(account_id, stable_key)`
uniqueness makes a re-import a no-op — preview marks the rows
`already_imported`, commit skips them. A profile with no id column falls back
to `"{profile}:{sha256(value_date, amount, currency, description,
row_number)}"` — the row number keeps two byte-identical rows in one file as
two movements while a re-import reproduces the same keys. **This does not
weaken ADR 0020 §5:** hand-entered rows (`KeyStrategy.MANUAL`) still have no
dedup — two identical cash coffees are still two movements — only
`IMPORTED` rows are keyed to a source id. `KeyStrategy.IMPORTED` needs no
migration (the column is a constraint-free `VARCHAR`; `imported` fits the
width).

**5. Satispay meal vouchers split into two movements.** The user's call: a
mixed row emits a `Disponibilità` movement on the primary manual account and
a `Buoni Pasto` movement on a separate "Buoni Pasto" manual account, each
only when non-zero. The parser refuses the row (`amount_split_mismatch`) if
`Disponibilità + Buoni Pasto != Importo`. The API requires
`voucher_account_id` when the file has voucher amounts
(`422 voucher_account_required`); the client makes it a required picker for
the Satispay profile so that case never reaches the server.

**6. Every imported movement is a booked manual transaction.** `booked_at`
is `None`, `status` is `booked`, `role` is `personal`,
`last_synced_at` stays `None` — identical to a hand-entered manual movement
(ADR 0020 §6), so it is editable, deletable, and outside pending-pruning.
Both target accounts must be manual and the user's
(`409 account_not_manual`).

**7. The `Descrizione` column is dropped.** It carries a payment id or a
masked IBAN (`(IT*****5579)`); a masked account number is still material
`data-safety.md` keeps out of the record. `Nome` becomes the description.
The handlers log only counts and reason codes — never a cell, a description,
or an amount.

## Consequences

- New: `domain/imports/` (`models`, `profiles`, `parse`),
  `services/imports.py`, `api/routers/imports.py` + `api/schemas/imports.py`,
  `imported_stable_keys` / `create_imported_transactions` in
  `db/repositories.py`, `KeyStrategy.IMPORTED`, `Settings.import_max_bytes`.
- Client: `ImportPreviewRequest` / `ImportPreviewResponse` /
  `ImportCommitResponse` models, `importPreview`/`importCommit` on the API
  client, `ImportTransactionsSheet` + `ImportTransactionsViewModel` reachable
  from a dashed card in Conti (shown once a manual account exists). File
  bytes are read and base64-encoded in the view; the view model stays
  I/O-free.
- A Satispay "Ricarica Satispay / Dalla Banca" row imports as a normal
  outgoing/incoming movement; once both legs exist it becomes an ordinary
  two-sided transfer suggestion via the existing engine (ADR 0022) — no
  special case.
- `docs/domain.md`: §Account (a manual account also receives imported rows),
  §Transaction Identity (`KeyStrategy.IMPORTED`), §Terms deliberately avoided
  ("Import" now has a real, distinct meaning — a file import, never a bank
  fetch, which stays "sync").

## Alternatives considered

- **A dedicated Satispay parser.** Rejected: every future source becomes a
  code change and a release; the layout differences are all expressible as
  profile data.
- **`multipart/form-data` upload.** Rejected: it adds `python-multipart` and
  a second request shape to a JSON-only client, for a few-KB file.
- **One combined `Importo` movement instead of the split.** Rejected by the
  user: they want both "bags" (balance and vouchers) tracked as real money,
  not folded together or dropped.
- **Reuse `KeyStrategy.MANUAL` / no dedup.** Rejected: a monthly re-import is
  the normal workflow; without dedup every month would double the overlap.
- **Convert xlsx to CSV by hand before upload.** Rejected: a recurring
  manual step is exactly the friction that stops an app being used
  (`tasks/ROADMAP.md`'s daily-driver bar).

## Revisit when

- A second file source needs a column shape the profile model cannot
  express (multiple currencies, a running-balance-only export with no
  per-row amount).
- The import is run against a very large file often enough that decoding
  cost matters — then stream rows instead of materializing them.
