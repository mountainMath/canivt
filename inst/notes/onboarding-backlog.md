# onboarding-backlog.md — staged onboarding of new `.ivt` candidates

The corpus was "fully supported" as of the 2026-07 sweep. A fresh random sample
of 20 catalogue tables (10 StatCan + 10 Borealis, none previously in the corpus)
surfaced **7 tables that do not read strict-clean** — 5 unsupported (fail the
family gate) and 2 that read only via loud fallbacks. All 7 raw `.ivt`s are now
in the ivt cache (`CANIVT_IVT_CACHE`, one folder per table) so they can be worked
systematically. This doc is the backlog + the repeatable onboarding workflow.

**Progress (2026-07-21): 4 of 7 landed in the Stage 1 pass** — see the Done
section at the bottom. The one Stage-1 fix (descriptor-name geotype recovery +
the `b3 == 08`-only exact-fit gate) cascaded through two Stage-2 tables and one
Stage-3 table. **3 remain: `table_6_c-ivt-2007`, `PRSIC1dec1999`** (and the
already-parsing `97-563-XCB2006058`, Stage 3).

Companion docs: format ref [`ivt-format.md`](ivt-format.md); marker catalog
[`markers.md`](markers.md); coverage [`coverage.md`](coverage.md); the narrative
of how each earlier table was cracked [`decode-history.md`](decode-history.md).

## The candidates

Diagnostics captured from `ivt_f2_descriptor()` / `ivt_layout()` /
`ivt_page_preflight()` (all under `ivt_quietly()`); cell counts from a successful
fallback `read_ivt()` where one exists.

| cache folder | source | sig | today | descriptor (recovered) | root-cause hypothesis | stage |
|---|---|---|---|---|---|---|
| `SP3_NIQKF5_95f0490xcb01006` | Borealis | `04` | unsupported | Values(1)×Profile(**256**)×Geography(**256**) | both dims pinned at 256 → true counts >256, need the u16 descriptor count (slot-dir blocks cap at 256) | 1 |
| `SP3_BJFWAP_95f0378xcb01004` | Borealis | `04` | unsupported | Geography(164)×Sex(3)×Age(5)×Marital(7)×PresenceOfChildren(11)×LabourForce(8) | descriptor looks complete → preflight rejects on layout/page-extent, not counts | 2 |
| `97-555-XCB2006058` | StatCan | `04` | unsupported | Geography(166)×Age(8)×Sex(3)×Selected-demographic(830, type `0x0a`)×MotherTongue(4) | descriptor plausible → preflight rejects; suspect the 830-member straddle / page width. Twin lineage `97-563-XCB2006072` is supported | 2 |
| `SP3_NIQKF5_95f0489xcb01007` | Borealis | `04` | **WARN** (86,696 cells) | Values(1)×Profile(336)×Geography(315) | reads via `canivt_descriptor_lenient` accept-all walk → make the primary doubled-name walk recover all 3 dims (strict-clean) | 3 |
| `SP3_AAV9RM_97-563-XCB2006058` | Borealis | `04` | **WARN** (75,913 cells) | 8 dims (Geo(1)×Age(7)×…×Year(2)) | reads via `canivt_fallback`+`canivt_geo_datadim` (geo block dir didn't resolve DGUIDs → byte-scan) → resolve the geo block directory | 3 |
| `SP3_HHP4CZ_table_6_c-ivt-2007` | Borealis | `04` | unsupported | **0 dims** — descriptor walk finds nothing | unrecognised descriptor structure within the modern generation; a new variant/lineage | 4 |
| `SP_XWJR2W_PRSIC1dec1999` | Borealis | `02` | unsupported | 0 dims | **earlier container generation** (`02 00 20 00`); an as-yet-unhandled gen02 variant (not the onboarded survey gen) | 5 |

## Staged plan

Stages are ordered by ascending risk/effort and grouped by shared machinery, so
each stage builds momentum and (mostly) reuses the previous fix. Stages are
independent — a later stage does not depend on an earlier one landing.

- **Stage 1 — descriptor count refinement (well-trodden).** ✅ **DONE
  (2026-07-21)** `95f0490xcb01006`. The root cause was NOT a u8/u16 count read
  (the byte walk already computed 621/1041 from the framing) — it was the
  geography prose-bleed name recovery being gated to `first_record`, while the
  profile lineage stores geography LAST, so the record was dropped and the
  descriptor rebuilt from the slot table (which caps at the first 256-member
  chunk). Fix + cascade in the Done section.
- **Stage 2 — layout/preflight for full-descriptor crosstabs.** ✅ **DONE
  (2026-07-21, cascaded)** `95f0378xcb01004`, `97-555-XCB2006058`. Both were
  rejected by the exact-fit pre-flight gate on `b3 == 09` pages that carry an
  allocation/mask tail; relaxing exact-fit to `b3 == 08`-only cleared both.
- **Stage 3 — promote fallback reads to strict-clean.** `95f0489xcb01007`
  ✅ **DONE (2026-07-21, cascaded)** — the descriptor-name geotype fix removed
  its lenient fallback (cell count unchanged). **`97-563-XCB2006058` REMAINS**
  (geo block directory must resolve the DGUID member blocks; still reads via
  `canivt_fallback`+`canivt_geo_datadim`).
- **Stage 4 — new modern descriptor variant.** `table_6_c-ivt-2007`. Descriptor
  walk recovers nothing → decode the descriptor framing this file uses; expect a
  new marker to catalog in `markers.md`.
- **Stage 5 — earlier container generation.** `PRSIC1dec1999` (`02 00 20 00`).
  Extend the gen02 path (`ivt_f2_descriptor_02` / container) to this variant.
  Largest unknown; do last.

## The per-table onboarding workflow (repeatable recipe)

Do one table at a time; land it fully (fix + validation + ledger + notes) in a
single commit before starting the next.

1. **Reproduce & pinpoint the rejection.** `devtools::load_all(".")`, read the
   raw, and run the gate stages under `ivt_quietly()` to see *where* it fails:
   ```r
   f   <- "<cache>/<folder>/<file>.ivt"; raw <- readBin(f, "raw", file.info(f)$size)
   d   <- ivt_quietly(ivt_f2_descriptor(raw)); str(lapply(d$dims, `[`, c("type","count","name")))
   lay <- ivt_quietly(ivt_layout(raw))       # straddle / geo_in_page / ipc / windows
   ivt_quietly(ivt_page_preflight(raw, lay)) # TRUE, or FALSE = the rejection
   ```
   Classify: **descriptor** (wrong dim count/name/missing dim), **layout**
   (straddle/geo choice), or **preflight** (page extent / exact-fit / capacity /
   span). This decides which R file to touch (`dimdir.R` / `codebook-f2.R` /
   `decode.R`).
2. **Get ground truth.** Prefer the file's own metadata; validate against an
   external source you do **not** hard-code a path to:
   - the Beyond 20/20 HTML viewer via internal `R/ground-truth.R`
     (`ivt_ground_truth(catalogue)` → per-cell values + member positions), or
   - the published CSV / WDS `getCubeMetadata` for true dim counts and spot cells.
   Record the expected total non-zero cell count and 2–3 spot cells.
3. **Fix generically (metadata-driven).** Per CLAUDE.md: no name/type branches, no
   hidden hard-coded parsing paths — drive off structural markers, counts, the
   2048-bit cap. If you decode/widen a byte marker, update `markers.md` **in the
   same commit** as the recognizer. Any new content-heuristic path must be wired
   through `ivt_fallback()` (loud, strict-upgradable) — never a silent read.
4. **Validate.** `read_ivt(f)` → cell count matches step 2; spot cells match.
   Then `withr::with_options(list(canivt.strict = TRUE), read_ivt(f))` must be
   clean, **or** the remaining fallback is justified and recorded as
   `strict_clean = FALSE`.
5. **Record.** Add/append in the same commit:
   - a row in `tests/testthat/fixtures/corpus-ledger.csv`
     (`key,supported,strict_clean,n_cells`),
   - a coverage bump in `coverage.md`, and a `decode-history.md` entry (what the
     file was, how it was cracked, the invariant behind the fix),
   - move the table's row here to a "Done" list.
6. **Regress.** Run the opt-in corpus ledger (it now includes these 7 folders):
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
- The corpus regression (`test-corpus.R`) and marker sweep both stay green.

## Definition of done (backlog)

All 7 tables have ledger rows and read at their validated cell counts; the sample
sweep that produced this list re-run clean. When that holds, fold the residue
back into `coverage.md`'s "fully supported" statement and retire this doc.

## Done

**2026-07-21 — Stage 1 pass (one fix, four tables).** Two small, general changes
in `R/codebook-f2.R` and `R/decode.R`:

1. **Geography prose-bleed name recovery for a geography-LAST record.**
   `ivt_f2_descriptor_name()` gained a `type` parameter; its "longest reoccurring
   title-case prefix" fallback (case e) now fires for any u16-count **geotype**
   record, not only `first_record`. The profile lineage stores its (large)
   geography dimension last, and 95F0490's two "Geography" name copies are
   interleaved with French prose (`Geographyens (pGeographytut de r`), so the
   strict walk was dropping the record and rebuilding the descriptor from the
   slot table — which caps at the **first 256-member chunk** (Profile's real 621,
   Geography's real 1041 are chunked codebooks). With the name recovered, the
   byte-walk's framing counts (`6d 02 0a 01` → 621; `11 04 0b 01` → 1041) stand.
2. **Exact-fit pre-flight only for `b2 == 0 && b3 == 08`** (no head, no tail).
   `b3 >= 09` pages may append an allocation/suppression-mask tail after the dense
   value run (95F0490's `b3 == 09` pages carry 8–80 byte tails; the 2006 vintage
   does it on `b3 >= 0a`). Decoding is presence-authoritative, so the tail is
   inert. Relaxing exact→`<=` for `b3 == 09` cannot break a table that was exact.

Landed (ledger rows flipped, corpus `test-corpus.R` green, FAIL 0):

| table | verdict | cells | validation |
|---|---|---|---|
| `SP3_NIQKF5_95f0490xcb01006` | strict-clean | 538,064 | 2001 labour-force accounting identities hold across all 1041 geos to ±10 (base-5 random rounding) |
| `97-555-XCB2006058` | strict-clean | 4,166,909 | Sex Total=M+F within ±11 on 96.7% of count cells; the residual is exactly the non-additive income medians/averages/SEs (members 795–830) |
| `SP3_BJFWAP_95f0378xcb01004` | fallback (`canivt_descriptor_from_slots`; a footnote bleeds into its descriptor) | 859,903 | Sex Total=M+F within ±11 on 99.6% of count cells |
| `SP3_NIQKF5_95f0489xcb01007` | strict-clean (was `canivt_descriptor_lenient`) | 86,696 | cell count unchanged from the prior validated fallback read; only the warning removed |
