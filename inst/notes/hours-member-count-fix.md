# Work plan — LFHR Table-023 Hours dimension mis-parsed (10 members read as 9)

Status: **DONE (2026-07-22)** — fix landed. `ivt_f2_dir_entry_members()`
(`R/codebook-f2.R`) widened to accept the `0x20` post-bitmap marker on the dense
member-description array. Hours now reads **10** members → Table-023 decodes
**5,771,932 cells** (was 4,986,342), labels un-shifted ("Total employed" first,
"Average usual hours (main job)" last). Additivity validated (Σ 7 buckets =
Total employed; Total usual / Total employed = Average). Corpus **FAIL 0 PASS 270**,
full suite **FAIL 0 PASS 1078**. Ledger + markers.md §F + coverage.md +
decode-history.md + CLAUDE.md updated. Secondary Sex EN/FR issue (below) NOT
addressed — left for a separate change as the plan directed.
Owner file touched: `R/codebook-f2.R` (`ivt_f2_dir_entry_members()`).

## TL;DR

`SP3/NAZQV2/Table-023` (Labour Force Historical Review, 6 dims) decodes
**4,986,342** cells but should decode **5,771,932**. The `Hours worked`
dimension has **10** members in the file but is parsed as **9**. This both
**drops 785,590 real cells** (the 10th member, "Average usual hours") and
**shifts every Hours label by one** (currently-shipped Hours labels are all
wrong). The descriptor *block* is correct (count = 10); the loss happens in a
slot-table rebuild fallback because a shared codebook reader can't parse this
survey lineage's member-description block framing.

This was found while investigating the "doubled-window directory" open concern.
Conclusion on that: the **directory** over-allocation padding is genuinely EMPTY
(verified) — it is NOT where data hides. The missing data is the 10th Hours
member inside the pages.

## Evidence (all reproducible read-only)

File: `/Users/jens/data/ivt_raw/SP3_NAZQV2_Table-023/Table-023.ivt`

- Layout: `counts = geo(11), sex(3), class(3), occupation(33), hours(9), timeseries(276)`;
  straddle = hours, inner = timeseries(276→512), `ipc = [4,276]`, `window_count = 3`;
  paged strides (doubled) `[1,8,512,2048,8192]`.
- Full directory scan: total presence bits **5,771,932**, decoded cells
  **4,986,342**, gap **785,590**. Every occupied directory entry decomposes
  cleanly into used ranges → **directory interstitial slots are empty**.
- The gap is entirely window 2 / hour-slot 2 (hours member **index 9**), and
  those cells carry real values (36.7 … 44.7 = average hours).
- Hours member ordering confirmed by value magnitudes AND additivity:

  | idx | label | sample | check |
  |----|-------|------|------|
  | 0 | **Total employed** | 11,714 | ≈ Σ buckets (905+1250+540+2334+4668+761+1255) ✓ |
  | 1-7 | 01-14h … 50h+ | 905 … 1255 | |
  | 8 | Total usual hours (main job) | 430,271 | |
  | 9 | **Average usual hours (main job)** | 36.7 | = 430271/11714 ✓ ← dropped |

- Descriptor block (offset 1568, `81 02 06 00`) framing for the Hours record is
  `0c 0a 05 01 "Hours worked"` → separator `01`, type `0x05`, **count `0x0a` = 10**.
  The forward master-dir walk reads this correctly (Hours = 10) but recovers only
  5 of 6 dims (the `Month`/Timeseries record has no standard `01` name anchor),
  so `length(dims) < ndim` and it is **pre-empted** by
  `ivt_f2_descriptor_from_slots()`.

## Root cause

`ivt_f2_descriptor_from_slots()` → `ivt_f2_slot_member_count(raw, dir5)` returns 9.

- Hours stores its member **descriptions** in a block framed
  `81 01 [f8 00 = 248-bit bitmap alloc] [32-byte bitmap] [0x20 marker] [10 Pascal records]`
  (block at off 57571660, len 229; a sibling FR block at 57571897, len 278).
- `ivt_f2_dir_entry_members()` (`R/codebook-f2.R:585`), in its `0x81` branch,
  skips the bitmap then requires the next byte ∈ `{0x80, 0x01, 0x10}` (line ~620).
  Here that byte is **`0x20`** → returns `NULL`.
- With the label array unread, `slot_member_count` falls to the member **CODE**
  array via `ivt_f2_code_array_members()`, which has only **9** entries (the
  "Total employed" total has no code) → count 9.
- Contrast: Class/Occupation use the plain `01 01 …` block format
  (`01 01 34 00 04 00`, `01 01 79 07 40 00`) which reads correctly *with* their
  "Total employed" member. A manual `rd_pascal` run from just past the `0x20`
  marker reads all 10 Hours labels perfectly, so the data is fully recoverable.

## Fix plan

1. **Widen `ivt_f2_dir_entry_members()`** to parse the `81 01`+bitmap block whose
   post-bitmap marker is `0x20` (this 04-gen survey lineage's member-description
   array). Keep it self-validating (records must be clean Pascal strings ending at
   the block end). Update `inst/notes/markers.md` in the SAME commit (new marker
   variant) and its self-check (`test-markers.R` / `IVT_MARKER_SET`).
2. Confirm the cascade: `slot_member_count(Hours) = 10` → `descriptor_from_slots`
   → Hours = 10 → decoder keeps hour index 9 → cells **5,771,932**; Hours labels
   un-shifted (`Total employed` first, `Average usual hours` last).
3. **Validate** against the additivity identities above (Σ buckets = Total
   employed; Average = Total usual / Total employed) across geos/months — these
   are now checkable and were not before.
4. **Corpus regression** — this framing is shared by the 04-gen survey lineage, so
   re-run the whole ledger. Expect member-count / label / **cell-count** changes on
   sibling tables (LFHR Table-051, justice h2530002, etc. — check each). Update
   every affected `fixtures/corpus-ledger.csv` row + `coverage.md` +
   `decode-history.md` in the landing commit. Do NOT land if any FAIL appears
   without being understood.
5. Prefer widening the shared reader over special-casing. If corpus fallout is too
   broad/risky, the alternative is to make the correct **descriptor block** counts
   win over the slot rebuild (the block already has Hours = 10) — but that needs
   the forward master-dir walk to survive recovering only 5/6 dims, which is a
   larger change. Decide after seeing step-4 fallout.

## Secondary issue (separate, lower priority)

**Sex** decodes to French ("Les deux sexes / Hommes / Femmes") though the English
"Both sexes" block exists in the file (off 57562519, EN block right before the FR
block at 57562554). EN/FR selection bug for this lineage. Investigate the
`ivt_f2_frscore` / `ivt_f2_dim_dict_en_first` choice for these blocks while in the
area, but land it separately from the Hours fix.

## Reproduce quickly

```r
devtools::load_all(".")
f <- "/Users/jens/data/ivt_raw/SP3_NAZQV2_Table-023/Table-023.ivt"
raw <- readBin(f, "raw", file.info(f)$size)
dd5 <- ivt_quietly(ivt_f2_dim_dir(raw, 5L))
ivt_quietly(ivt_f2_slot_member_count(raw, dd5))          # 9 (should be 10)
# manual proof the 10 labels are there:
i <- 57571697L; repeat { r <- rd_pascal(raw, i); if (is.null(r)) break; cat(nchar(r$text), r$text, "\n"); i <- r$end }
```

## Do NOT regress

- The directory-doubling padding is EMPTY — don't chase it as the source of the
  missing cells (it isn't). See `coverage.md` "Open concerns" — the doubling stays
  a separate open geometry question; this Hours fix does not resolve or depend on it.
- Fix must stay metadata-driven (no name/type branch on "Hours"); key off the
  block framing only.
