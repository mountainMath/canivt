# onboarding-backlog.md — staged onboarding of new `.ivt` candidates

The corpus was "fully supported" as of the 2026-07 sweep. A fresh random sample
of 20 catalogue tables (10 StatCan + 10 Borealis, none previously in the corpus)
surfaced **7 tables that do not read strict-clean** — 5 unsupported (fail the
family gate) and 2 that read only via loud fallbacks. All 7 raw `.ivt`s are now
in the ivt cache (`CANIVT_IVT_CACHE`, one folder per table) so they can be worked
systematically. This doc is the backlog + the repeatable onboarding workflow.

**Progress (2026-07-21): ALL 7 landed.** The Stage-1 pass cleared 4 (one fix +
cascade); Stages 3–5 then landed the remaining 3 — `97-563-XCB2006058` (uid-less
custom geography routed to the data-style reader), `table_6_c-ivt-2007` (UCR
inverted descriptor rebuilt from the slot table), and `PRSIC1dec1999` (earlier
`02`-gen, now **strict-clean**). See the Done section at the bottom. The backlog
is cleared — fold the residue back into `coverage.md`'s "fully supported"
statement and retire this doc.

**Second random sweep (2026-07-21).** A fresh 10 StatCan + 10 Borealis sample
(none in the corpus): all 10 StatCan decoded; of the 10 Borealis, 5 decoded, 3
were 403-blocked (access-restricted OCDMVE dataset, not a decode gap), and two
`04`-gen survey tables failed and are now onboarded (ledger + `decode-history.md`
"Second random sweep") — `SP3_THNM6I_00040231` (Census of Agriculture overview:
`@32`→identity block, real descriptor recovered by a FORWARD master-directory
variant of the inverted retry) and `SP3_Q2JJJO_table_5_c-ivt-2008` (UCR crime:
`[used][allocated]` directory entries + a `b3==08` allocation-padding tail, both
`04`-gen adaptations of allowances the `02`-gen already had). Corpus FAIL 0.

**Open focused investigation (2026-07-22): the `04`-gen survey directory geometry
(LFHR multi-dim).** A later sweep drew `SP3/NAZQV2/Table-023` (Labour Force
Historical Review 2009, 6 dims incl. a 276-month Timeseries) — the first
*multi-dimensional, long-series* member of the otherwise-onboarded survey lineage
(LFHR `Table-051`/UCR/justice). It needs one small real fix (`ivt_f2_time_members()`
must read `alloc` as a full u16 — Table-023's alloc = 512 trips the `alloc < 256`
guard) AND a genuine reverse-engineering of the lineage's directory paging: with the
descriptor recovered the in-page dimension decodes exactly (Canada total-employed
matches LFS) but the directory-paged dims scramble under both the pow2-padded and
the dense stride models. **Not an in-family fix** — see
[`coverage.md`](coverage.md) "Future focused investigation" for the full diagnosis
and the [`sampled-tables.csv`](sampled-tables.csv) `Table-023` row.

**Sampling log — [`sampled-tables.csv`](sampled-tables.csv).** Every table drawn
in a random sweep is now recorded there (one row per `sweep_date`/`source`/`key`
with `outcome` ∈ {`decoded_clean`, `decoded_fallback`, `onboarded_fixed`,
`http_403_blocked`, `error`} + `n_cells`/`note`), so future sweeps can DEDUP
against it instead of re-drawing the same tables. Only tables we onboard land in
the corpus ledger; this log is the fuller record of what has been *tried* (incl.
the ones that just worked and the access-blocked ones). The 2026-07-21 second
sweep seeds it with its 20 rows (8 clean / 7 fallback / 2 fixed / 3 403-blocked);
back-fill earlier sweeps opportunistically.

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
| `SP3_AAV9RM_97-563-XCB2006058` | Borealis | `04` | ✅ **DONE** (75,913 cells, `canivt_geo_datadim`) | 8 dims (Geo(1)×Age(7)×…×Year(2)) | ~~geo block dir didn't resolve DGUIDs~~ — no DGUID exists (uid-less custom field dict); routed to data-style geo reader | 3 |
| `SP3_HHP4CZ_table_6_c-ivt-2007` | Borealis | `04` | ✅ **DONE** (1,952 cells, `canivt_descriptor_from_slots`) | Geo(1)×ClearanceType(19)×Offences(187)×Year(1) | UCR survey lineage: INVERTED descriptor (records before an `80 01` signature) rebuilt from the header slot table | 4 |
| `SP_XWJR2W_PRSIC1dec1999` | Borealis | `02` | ✅ **DONE** (2,652 cells, **strict-clean**) | PROV/CAN(14)×DIVISIONS(19)×EMP.SIZE(11) | earlier `02`-gen: dir with interior null holes + `81 01` dense member array (`0x10` marker) + `English Label` schema vocabulary | 5 |

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
  its lenient fallback (cell count unchanged). `97-563-XCB2006058`
  ✅ **DONE (2026-07-21)** — the "geo block dir didn't resolve DGUIDs" hypothesis
  was wrong: this single-area custom extract's geography field dictionary declares
  only name columns (`English Desc / Desc française / short name`), **no UID**, so
  there is no DGUID to resolve. The double warning was the dispatcher running the
  DGUID byte-scan (step 5) before the data-style reader (step 5b). Gated step 5 on
  `enc != "custom" || ivt_f2_geo_field_has_uid()`, so a uid-less custom dictionary
  routes straight to `ivt_f2_geo_datadim`. Now a single documented
  `canivt_geo_datadim` fallback (`strict_clean = FALSE`, cells unchanged 75,913).
- **Stage 4 — new modern descriptor variant.** `table_6_c-ivt-2007`
  ✅ **DONE (2026-07-21)**. Not a new framing — the UCR survey lineage (sibling of
  the onboarded `ucr2.2_3-2006`) stores its descriptor records INVERTED before a
  signature ending `80 01` (not `80 03`/`80 ff`), off an `81 02 04 00` sub-header
  the `81 02 03 00` inverted-retry misses; its 1-member `Year` reference-period
  dimension the name-keyed member counter cannot size, so both the forward walk
  and `ivt_f2_dims_from_slots()` come up empty. Fix: `ivt_f2_descriptor_impl()`
  now falls back to `ivt_f2_descriptor_from_slots()` (name-independent slot member
  counter) when the walks come up short, plus a `56 00` survey-name-marker cleaner
  in `ivt_f2_dim_marker_name()`. Reads Geo(1)×ClearanceType(19)×Offences(187)×
  Year(1) → **1,952 cells** (`canivt_descriptor_from_slots`, `strict_clean = FALSE`,
  as with the other survey-lineage tables). Validated: the clearance-status
  accounting identities (Total = Not cleared + Cleared by charge + Cleared
  Otherwise; the nested Cleared-Otherwise / Other-Clearances subtotals) hold
  EXACTLY across all 177 offences.
- **Stage 5 — earlier container generation.** `PRSIC1dec1999` (`02 00 20 00`)
  ✅ **DONE (2026-07-21, strict-clean)**. Three small, general fixes — NOT a
  bespoke gen02 path: (1) `ivt_f2_dim_dir()` now accepts a directory that is
  complete but sparse (its `want` declared slots are all either well-formed
  entries or explicit `(0,0)` null holes) — the "Employment size ranges" dimension
  has 5 interior holes across 19 slots, beyond the old 4-null tolerance, which
  blocked BOTH `ivt_f2_descriptor_02()` and the slot rebuild; (2) the `81 01`
  dense member-array reader (`ivt_f2_dir_entry_members()`) accepts a `0x10`
  pre-records marker byte (this generation's dense arrays; was `0x80`/`0x01`),
  recovering the 11-member size-range array; (3) `ivt_f2_dim_dict_en_first()`
  anchors on the `English Label` phrase (the EN field name is followed by binary
  bleed that broke `\bLabel\b`). Reads PROV/CAN(14)×DIVISIONS(19)×EMP.SIZE(11) →
  **2,652 cells strict-clean**. Validated: Canada = Σ provinces, DIVISIONS Total =
  Σ divisions, and the employment-size hierarchy (Total(A) = Indeterminate(B) +
  Subtotal(A−B); Subtotal = Σ 8 ranges) all hold EXACTLY.

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
