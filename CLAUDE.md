# CLAUDE.md — canivt

Guidance for working on **canivt**, an R package that downloads and parses
StatCan *Beyond 20/20* `.ivt` tables into tidy data / Parquet / CSV, and extracts
their metadata (dimension members, geographic identifiers/DGUIDs, footnotes).

This folder is self-contained. The authoritative file-format reference is
[`inst/notes/ivt-format.md`](inst/notes/ivt-format.md) — **read it before changing
the parser.** A user-facing version is the vignette `vignettes/ivt-format.Rmd`.
[`inst/notes/coverage.md`](inst/notes/coverage.md) is the **living completeness
tracker** (what we decode vs what's left, with measured byte coverage) — **update
it whenever a gap is closed or a new one is found.**

## What works today

Fully decodes and validates the **2021-era Beyond 20/20 layout** (reference table
98-10-0241): all 166 geographies, 7,489,464 cells, exact vs the StatCan CSV;
plus all dimension labels, geography DGUIDs, and footnotes. Whole-file pure-R
decode runs in ~4–5 s.

There are **two container families** under the shared `04 00 20 00` signature,
both decoded:
- **Family 1** — per-geography page directories at a fixed stride (98-10-0241).
- **Family 2** — one contiguous page directory. The cell decoder is
  **n-dimensional** (descriptor-driven): it handles any number of dimensions,
  computing geographies-per-page, the power-of-two-nested presence bitmap, and the
  per-marker value layout from the header. Validated cell-exact on
  **98-10-0023** (3-dim Age×Gender, 4 geos/page, all 63,404 geographies) **and
  98-10-0129** (4-dim Gender×Marital×Age, 2 geos/page, all 15,685,859 cells incl.
  the `0xa4` int32 marker). Codebook fully decoded for 98-10-0023: **Age/Gender
  member labels** and the **full
  geography attribute table** — name, DGUID, level, type abbreviation, province
  abbreviation, two geocodes, the **data-quality flag** and **non-response rate**
  — all validated exact vs the metadata for 63,404 geographies (GEO_TYPE_DESC and
  DQF_NOTE ~99.8%, a few cells in the largest group where long text splits across
  blocks). `read_ivt(geo_attributes = TRUE)` decodes the attribute table (adds a
  ~30 s codebook block-scan) and `ivt_tidy()` then labels by `geo_name` +
  `geo_level`; the default keeps geographies keyed by DGUID. `read_ivt()`
  auto-detects the family via `ivt_family()`.

The **1991 census** layout (e.g. `1003011`, E9101) is also wired into `read_ivt()`
now: same family-2 container with int16/int32 pages (markers `0x84`/`0x82`) and a
pre-DGUID inline codebook. Cells validated **330/330 exact** for all 8 scraped
ground-truth geographies; geography (bilingual names + GEOUIDs), Age(110)/Sex(3)
labels, dimension metadata and identity all decode. Geography metadata comes from
the header (`ivt_f2_geo_is_inline()`, `ivt_f2_header_geo_count()`); the page
directory is read from the header pointer (`u16@558`), not a marker scan. Other
unrecognised files are still rejected via `ivt_is_supported()`.

## Code map (`R/`)

| file | role |
|------|------|
| `utils-bytes.R` | low-level readers: `rd_u16/rd_u32/rd_int_run/rd_pascal`; latin-1 decode. **All offsets are 0-based** (binary layout); helpers convert to R's 1-based indexing. |
| `container.R`   | family-1 geography index + page directory; constants `IVT_IDX0=37167`, `IVT_IDX_STRIDE=0x1000`, `IVT_PAGES_PER_GEO=288`; page header/value-start logic. |
| `decode.R`      | family-1 presence-bitmap + dense value decode → cell tibble (vectorised per page; `IVT_GRID` precomputed group order). |
| `container-f2.R`| family-2 page directory finder + per-page value params (`IVT_F2_PAGE_TRAILER` per marker → `vstart = 4 + presence_len + trailer`; width/float from the low nibble); **computed** `ivt_f2_geos_per_page()` and `ivt_f2_geography_count()` (descriptor geo count / page count). |
| `decode-f2.R`   | **n-dimensional** family-2 decode: `ivt_f2_bit_layout()` (power-of-two-nested strides from the data-dim counts) + `ivt_f2_cell_grid()` (cells in dense value order) + `ivt_f2_record_present()` (**byte-pair-swap**, **MSB-first** bit read) → cell tibble with one column per data dimension. |
| `codebook-f2.R` | family-2 codebook: member-ordered geography DGUIDs (fast vectorised `2021…` Pascal-string scan, first-appearance dedup); data-dimension member labels (tail scan; EN block precedes the `1..n` ordinal block); and the full **geography attribute table** `ivt_f2_geo_attributes()` (segments the attribute-major growing groups via the DGUID anchor; `group_lo = d0 − 10·G`; per-attribute EN-then-FR slots). Also `ivt_f2_geo_inline()` for the **pre-DGUID 1991 layout** (`"name (GEOUID) flag"` blocks; bilingual names). One metadata-driven entry point `ivt_f2_geographies()` reads the layout + geography count from the **header** (`ivt_f2_geo_is_inline()`, `ivt_f2_header_geo_count()`, `ivt_f2_descriptor()`), dispatches to the right parser, returns a unified `member_id/geo_name/geo_uid/…` table, and validates the row count against the header (`ivt_f2_check_geo_count()`). |
| `read-f2.R`     | family-2 reader `ivt_f2_read()`, metadata (`ivt_f2_metadata()` incl. DGUIDs + dimension member labels), and `ivt_f2_tidy()` (label by DGUID + member names). |
| `codebook.R`    | header identity, dimension member blocks, geography names + DGUIDs, footnotes (family-1 codebook). |
| `read.R`        | public `read_ivt()`, `ivt_metadata()`, `ivt_tidy()`, `print.ivt`; `ivt_family()` detector + `ivt_is_supported()` gate. |
| `catalogue.R`   | scrapes the StatCan census datasets index (`https://www12.statcan.gc.ca/datasets/Index-eng.cfm?Temporal=<year>`) into a product catalogue. `statcan_ivt_years()` reads the `Temporal` selector; `statcan_ivt_catalogue()` scrapes every version into a tibble (census_year/catalogue/date/topic/title/pid/ivt_url/download_url/http_url), cached as Parquet in the data cache. `statcan_ivt_resolve_url()` forwards an `Alternative.cfm?PID=` link to its direct `Download.cfm?PID=` URL (b2020 `.zip` URLs returned unchanged). Needs `rvest`+`xml2`. |
| `get.R`         | `get_statcan_ivt(catalogue)` — one-stop accessor: resolves a catalogue number via the catalogue **or** a custom identifier matching a local `.ivt` in the ivt cache, downloads (`statcan_ivt_download()` sniffs zip vs raw IVT), decodes, caches the tidy Parquet, returns an `arrow::open_dataset()` connection (path on `attr(.,"path")`). Second call skips download+decode. |
| `ground-truth.R` | **internal, not exported** — scrapes the public Beyond 20/20 HTML viewer (`Rp-eng.cfm`, reached by following the catalogue `http_url`'s `URLRedirect`) to build decoder validation fixtures. `ivt_gt_viewer_url()` resolves the viewer (httr2 GET, not HEAD — `URLRedirect.cfm` 302s HEADs to a 404); `ivt_gt_slice(url, gid, fixed)` fetches one pivot slice (state driven by GET params via `ivt_gt_set_params()`, which **replaces** keys — duplicate `GID`/`dN` 404s); `ivt_ground_truth(catalogue, max_geos)` loops geographies. The parser keys off stable markup (`table#tabulation`, `select#d0[name=GID]`, cell `title="[Row N: …] [Column M: …]"`); it returns one row per cell with a `value` plus, per dimension, a slug label column + 1-based `<slug>_id` position (the **position** is the label-independent join key, since HTML slugs `single`/`sex` differ from the decoder's `age`/`gender`). Validated: 1991 decode matches scrape **660/660** for Canada+NL. |
| `cache.R`       | `ivt_cache_dir("ivt"\|"data")` resolves the two optional cache dirs (options `canivt.ivt_cache` / `canivt.data_cache`, falling back to `tempdir()`); `ivt_cache_is_set()`. |
| `zzz.R`         | `.onLoad` seeds the cache options from `CANIVT_IVT_CACHE` / `CANIVT_DATA_CACHE` env vars (so they can live in `.Renviron`) without overriding set options; `.onAttach` warns once if `canivt.data_cache` is unset. |
| `download.R`    | `ivt_download()` from the b2020 endpoint (defaults `dest_dir` to the ivt cache); `ivt_pid8()`. |
| `write.R`       | `ivt_write_parquet()/_csv()/_metadata()`; `ivt_label_depth()`. |
| `canivt-package.R` | `ivt_read_table()` one-shot wrapper + package doc. |

## Key invariants (don't regress)

- Index stride is **`0x1000`**, giving **166** geographies in metadata member
  order (directory `n` → Member ID `n+1`). Striding by `0x8000` silently reads
  only every 8th geography — the original bug.
- Presence bytes are pair-swapped (`bitwXor(housing, 1)`); the value stream is
  **not** swapped. Tenure `t` uses bit `7 - t`.
- Member id columns in `cells` are **1-based** (match StatCan Member IDs); the
  `Coordinate` field in the CSV ground truth is also 1-based.
- **Family 2**: directory entries are in **geography member-id order**;
  geos-per-page is **computed** (`geo_count / n_pages` — 4 for the 3-dim tables,
  2 for 98-10-0129), never assumed. The page marker's **low nibble is the
  value-width code** (`0x8`→float64, `0x4`→int32, `0x2`→int16); the high nibble
  (`0x8` vs `0xa`) only changes the pad/`0xFF` trailer length — `0xa` is **not** a
  suppression flag, `0xa*` pages carry real inline data.
- **Presence is a power-of-two-nested positional bitmap** over the data
  dimensions (descriptor order, outermost first; each level padded to the next
  power of two of count × inner-block; innermost in the low bits). Records are
  **byte-pair-swapped** then read **MSB-first**. The historical "Age nibble,
  genders Total/Men/Women at bits 3/2/1" is the Age×Gender special case.
- Value run starts at `4 + presence_len + trailer[marker]`
  (`presence_len = rec_bytes × geos_per_page`); trailers 4/10/34/18/8/16 for
  `0x88/0xa8/0xa2/0xa4/0x84/0x82`. The store keeps only **non-zero** cells (the
  CSV publishes the zeros), so a missing cell = 0; entirely empty geographies
  (zero presence record) are normal.
- Member id columns in `cells` are **1-based**; data columns are named by a
  per-dimension slug (`0x02`→`gender`, `0x07`→`age`, else the name's leading
  word, e.g. `marital`).
- Use `ivt_f2_geo_count()` (descriptor geography record), **not**
  `ivt_f2_header_geo_count()` (the fixed-offset u16 reads a wrong 16320 for 4-dim
  descriptors), for any geography sizing.

## Dev workflow

```r
devtools::load_all(".")
devtools::document()          # after changing roxygen comments
devtools::test()             # unit tests always run; decode tests need a sample
devtools::check()
```

Integration tests in `tests/testthat/test-decode.R` need a real `.ivt`; point
`CANIVT_SAMPLE_IVT` at a copy of `98100241.ivt`, e.g.

```sh
CANIVT_SAMPLE_IVT=/path/to/98100241.ivt Rscript -e 'devtools::test()'
```

They auto-skip if no sample is found (they also fall back to
`~/projects/censusmapper-import/data/raw/98100241/98100241.ivt` if present — the
sibling reverse-engineering repo where the format was originally cracked).
Family-2 integration tests in `tests/testthat/test-decode-f2.R` likewise need
`CANIVT_SAMPLE_IVT_F2` pointed at a copy of `98100023.ivt` (fallback
`/tmp/t23/98100023.ivt`); the 4-dimension test needs `CANIVT_SAMPLE_IVT_F2_4D`
pointed at `98100129.ivt` (fallback `/tmp/t129/98100129.ivt`), and the 1991 test
`CANIVT_SAMPLE_IVT_1991` at `1003011.IVT`.

`.ivt` and large `.csv` files are git-ignored; never commit them.

## Likely next tasks

- **N-dimensional family-2 decode — DONE.** `decode-f2.R` is descriptor-driven and
  validated cell-exact on the 4-dim 98-10-0129 (incl. the `0xa4` marker) plus the
  3-dim/legacy tables (158 tests green). Remaining nicety: the geography
  **DGUID member-ordering** has a few tail artifacts (`ivt_f2_geo_dguids()`
  first-appearance dedup) — the *cell* decode by member id is complete and exact,
  but a handful of DGUID *labels* near the end can be misordered (the same
  ~99.8% class as the geo-attribute note); empty geographies decode as zero cells.
- The **2001/2006 "F"-series** products (`97F0015XCB2001041`, `98F0172X`) are not
  yet decoded — possibly an older B2020 variant; need a confirmed local copy.
- **Family-2 geography attributes — DONE.** `ivt_f2_geo_attributes()` decodes all
  11 codebook attributes (name, DGUID, level, type abbr, prov abbr, two geocodes,
  data-quality flag, non-response rate; `GEO_TYPE_DESC`/`DQF_NOTE` decodable but
  not exposed: ~99.8% from long-text block splits). Validated exact vs metadata.
  Remaining niceties: (a) the 2 NA names from special-character truncation
  (`Sambaa K’e`), (b) `GEO_TYPE_DESC`/`DQF_NOTE` to 100% (needs block-finder
  fidelity for long text in the largest group), (c) speed up the ~30 s codebook
  block-scan if it becomes a bottleneck.
- Wire the **1991** `1003011` container into `read_ivt()`. **Geography is done**:
  `ivt_f2_geo_inline()` decodes all 41,859 geographies (bilingual name + GEOUID +
  quality flag) exact — container detection and the block scanner carry over from
  2021, but the codebook is the pre-DGUID inline `"name (GEOUID) flag"` layout
  (`ivt_f2_geo_is_inline()` routes to it). Still to wire: Age(110)/Sex(3) labels
  (bilingual), the int16/int32 cell decode (dense validated, sparse byte-pair-swap
  cracked), and a family-detector that admits 1991 into `read_ivt()`.
- Footnote *text* extraction is robust (maximal text-byte runs; all 10 EN + 10
  FR recovered, exact vs the metadata). Remaining nicety: attribute each footnote
  to the dimension/member it annotates (by codebook proximity or note ids).
- Optional: expose the per-dimension `depth` directly on `ivt_tidy()` output.
- Consider an `Rcpp` fast path only if pure-R decode becomes a bottleneck (it is
  fine at ~5 s for the reference table).

## Provenance

The IVT format was reverse-engineered in a separate repo
(`~/projects/censusmapper-import`, Python reference decoders `python/ivt2021.py`
and `python/ivt2021_codebook.py`). `canivt` is the standalone R port; it does not
depend on that repo at runtime.
