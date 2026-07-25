# onboarding-backlog.md — the per-table onboarding recipe

**The backlog is CLEARED.** Four random sweeps (2026-07-21 … 07-23) plus two
metadata-harvest sweeps flagged 20-odd tables; all are onboarded or ledgered as
deliberately UNSUPPORTED. What survives here is the **repeatable recipe** for the
next sweep. Per-table narratives live in [`decode-history.md`](decode-history.md);
current status in [`coverage.md`](coverage.md); refusals in
[`unsupported-formats.md`](unsupported-formats.md).

**Sampling log — [`sampled-tables.csv`](sampled-tables.csv).** Every table drawn in
a random sweep is recorded there (one row per `sweep_date`/`source`/`key` with
`outcome` ∈ {`decoded_clean`, `decoded_fallback`, `onboarded_fixed`,
`http_403_blocked`, `error`} + `n_cells`/`note`) so later sweeps **dedup against it**
instead of re-drawing. Only onboarded tables land in the corpus ledger; this log is
the fuller record of what has been *tried*.

## The per-table onboarding workflow

Do one table at a time; land it fully (fix + validation + ledger + notes) in a
single commit before starting the next.

1. **Reproduce & pinpoint the rejection.** `devtools::load_all(".")`, read the raw,
   and run the gate stages under `ivt_quietly()` to see *where* it fails:
   ```r
   f   <- "<cache>/<folder>/<file>.ivt"; raw <- readBin(f, "raw", file.info(f)$size)
   d   <- ivt_quietly(ivt_f2_descriptor(raw)); str(lapply(d$dims, `[`, c("type","count","name")))
   lay <- ivt_quietly(ivt_layout(raw))       # straddle / geo_in_page / ipc / windows
   ivt_quietly(ivt_page_preflight(raw, lay)) # TRUE, or FALSE = the rejection
   ```
   Classify: **descriptor** (wrong dim count/name/missing dim), **layout**
   (straddle/geo choice), or **preflight** (page extent / exact-fit / capacity /
   span). That decides the file to touch (`dimdir.R` / `codebook-f2.R` / `decode.R`).
2. **Get ground truth.** Prefer the file's own metadata; validate against an external
   source you do **not** hard-code a path to — the B20/20 HTML viewer via internal
   `R/ground-truth.R` (`ivt_ground_truth(catalogue)`), or the published CSV / WDS
   `getCubeMetadata`. Record the expected non-zero cell count and 2–3 spot cells.
3. **Fix generically (metadata-driven).** No name/type branches, no hidden hard-coded
   paths — drive off structural markers, counts, the 2048-bit cap. If you decode or
   widen a byte marker, update `markers.md` **in the same commit** as the recognizer.
   Any new content-heuristic path goes through `ivt_fallback()` — never a silent read.
4. **Validate.** `read_ivt(f)` → cell count and spot cells match step 2. Then
   `withr::with_options(list(canivt.strict = TRUE), read_ivt(f))` must be clean, **or**
   the surviving fallback is justified and recorded as `strict_clean = FALSE`.
5. **Record**, in the same commit: a row in
   `tests/testthat/fixtures/corpus-ledger.csv` (`key,supported,strict_clean,n_cells`),
   a coverage bump in `coverage.md`, and a `decode-history.md` entry (what the file
   was, how it was cracked, the invariant behind the fix).
6. **Regress.**
   ```sh
   CANIVT_CORPUS_TESTS=1 CANIVT_IVT_CACHE=~/data/ivt_raw \
     Rscript -e 'devtools::test(filter = "corpus")'
   ```
   plus `devtools::test()` and the marker sweep. FAIL count must stay 0.

## Definition of done (per table)

- `read_ivt()` decodes with the exact non-zero cell count validated against an
  external ground truth (viewer / CSV / WDS).
- Strict mode is clean, **or** the surviving path is a single documented loud
  `canivt_*` fallback with `strict_clean = FALSE` in the ledger and a reason.
- Ledger row + `coverage.md` + `decode-history.md` updated in the landing commit.
- `test-corpus.R` and the marker sweep stay green.

When a table cannot be onboarded honestly, ledger it `supported = FALSE` (with the
reason in `unsupported-formats.md`) rather than emitting unvalidated values.

## What the sweeps taught (recurring root causes)

Check these first — most rejections in the last four sweeps were one of them:

| symptom | usual cause | fix that landed |
|---|---|---|
| a dimension read as exactly **256** | count taken from a slot-directory member block, which caps at one 256-member chunk | `ivt_f2_slot_chunked_count()` via `ivt_f2_dim_count_reconcile()` (`canivt_chunked_count`) — recovers the true chunked count on both the generic and `02`-gen paths |
| descriptor short by one dimension | an unadmitted record framing (`01 02` reference-period facet; bare-`02` name separator; INVERTED records before the signature; prose bleeding into names) | widen `ivt_f2_descriptor()`'s anchors; last resort `ivt_f2_descriptor_from_slots()` |
| preflight rejects a plausible descriptor | exact-fit demanded on a page with a head block / allocation tail | exact fit only for `b2 == 0 && b3 == 08`; `≤` otherwise |
| directory looks "doubled" | the dimension's **declared slot allocation** exceeds `nextpow2(count)`, or an interior **deleted member slot** leaves gaps | `ivt_f2_dim_slot_alloc()` pads to the declaration; `ivt_f2_dim_slot_expand()` for deleted slots (`canivt_deleted_slot`) |
| large `canivt_skipped_pages` count | sparse directory over-walked by the cartesian, resolving onto codebook bytes | `ivt_skip_is_lost_page()` — an entry counts only if its target validates as a page by geometry |
| geography has no DGUID | uid-less custom field dictionary — there is nothing to resolve | route to the data-style reader (`canivt_geo_datadim`) |
