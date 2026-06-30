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

**One unified, descriptor-driven cell decoder** handles every table
(`decode.R`: `ivt_layout()` + `ivt_decode()`). The historical "family 1 / family
2" split is **not two formats** — it is one power-of-two-nested positional layout
where the only difference is *which dimension straddles the 2048-bit page boundary*
(see "Key invariants"). No code branches on dimension names or type bytes;
geography is dimension 1 *structurally*, the straddle/paging is derived from member
counts and the 2048-bit cap, and human-readable labels come from the codebook at
`tidy` time. Validated **cell-exact (byte-identical to the two former decoders)**
on all six reference tables:

- **98-10-0241** (7-dim, Period straddles): 166 geos, 7,489,464 cells, exact vs CSV.
- **98-10-0077** (7-dim incl. a reference-period Year, Ages straddles): all 174
  geographies, ~37M cells, exact vs CSV.
- **98-10-0662** (5-dim, Health straddles; small file, mixed int16/int32 pages,
  0x80 per-geo stride): all 91 geographies, exact vs CSV. (Was silently misdecoded
  before the unification — it had been misrouted to the family-2 decoder.)
- **98-10-0023** (3-dim Age×Gender, **geography straddles** → 4 geos/page): all
  63,404 geographies. **98-10-0129** (4-dim, geography straddles → 2 geos/page):
  all 15,685,859 cells incl. the `0xa4` int32 marker. **1991** `1003011` (3-dim,
  geography straddles → 4 geos/page; int16/int32 pages): 330/330 exact.

`read_ivt()` auto-detects via `ivt_family()`, which now only selects the
**metadata** path (the cell decode is shared). Metadata: 98-10-0023's full
geography attribute table (name, DGUID, level, type/prov abbreviation, two
geocodes, data-quality flag, non-response rate) decodes exact for all 63,404
geographies (`read_ivt(geo_attributes = TRUE)`, ~30 s block-scan; GEO_TYPE_DESC /
DQF_NOTE ~99.8%); 1991 geography (bilingual names + GEOUIDs) via the pre-DGUID
inline codebook. Unrecognised `04 00 20 00` products (e.g. the older 2016-census
98-400-X variant) are rejected via `ivt_is_supported()`.

## Code map (`R/`)

| file | role |
|------|------|
| `utils-bytes.R` | low-level readers: `rd_u16/rd_u32/rd_int_run/rd_pascal`; latin-1 decode. **All offsets are 0-based** (binary layout); helpers convert to R's 1-based indexing. |
| `container.R`   | page-directory anchor `ivt_idx0()` (reads `u16@558`, validates by checking the first entry points at a page marker — works for any file size) + the legacy 0x1000-stride `ivt_geography_count()` (kept only for the family detector / regression). `IVT_IDX0_DEFAULT=37167` is a fallback. |
| `decode.R`      | **the unified cell decoder.** `ivt_layout()` nests every dimension (data innermost, geography outermost), finds the one straddle dim at the 2048-bit page cap, and computes in-page / straddle / paged roles, the in-page bit grid, and the 8-byte directory-entry strides. `ivt_decode()` walks the paged-coordinate cartesian, decodes each page (`ivt_f2_record_present()` + marker-driven value-start `ivt_value_trailer()`) → cell tibble (`geo` + one slug column per data dimension). Handles geography-paged (former family 1) and geography-in-page/multiple-geos-per-page (former family 2) identically. |
| `container-f2.R`| family-2 page-directory finder (used by the metadata path) + per-page value params (`IVT_F2_PAGE_TRAILER` per marker); `ivt_f2_geos_per_page()` / `ivt_f2_geography_count()`. |
| `decode-f2.R`   | shared presence-bitmap primitives used by `ivt_layout()`/`ivt_decode()` for **every** table (the `ivt_f2_` prefix is historical): `ivt_f2_nextpow2()`, `ivt_f2_bit_layout()` (power-of-two-nested strides), `ivt_f2_cell_grid()` (cells in dense value order), `ivt_f2_record_present()` (**byte-pair-swap**, **MSB-first** bit read). |
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
- Member id columns in `cells` are **1-based**. Data columns are named by a
  **purely generic, name-agnostic slug** (`ivt_dim_slug()`): dimension 1 is
  geography → `geo` (structural), every other dimension takes the lower-cased
  leading word of its metadata name (`marital`, `tenure`, `single`, …), made
  unique. **No code branches on dimension names or type bytes** — dimensions are
  interchangeable; everything the decoder needs is structural (positions, counts,
  the 2048-bit cap). Human-readable labels come from the codebook at `tidy` time.
- Use `ivt_f2_geo_count()` (descriptor geography record), **not**
  `ivt_f2_header_geo_count()` (the fixed-offset u16 reads a wrong 16320 for 4-dim
  descriptors), for any geography sizing.
- **Geography is the first descriptor dimension** (`ivt_f2_geo_dim()`), identified
  **positionally, not by a type byte**: the geography descriptor *type* differs by
  format (`0x10` in modern 2021 family-2 files, count u16; `0x08` in the family-1
  reference table, count u8). The old `type == 0x10` filter silently misread
  98-10-0241's geography count as 16383. `ivt_f2_data_dims()` likewise takes "all
  dims after the first" rather than filtering by type.
- **`ivt_f2_descriptor()` anchors dimension records on the doubled name**, not on a
  fixed `<type> 01 <upper>` marker (the type list is gone). Each record stores its
  name twice back-to-back after a `0x01`; count/type framing bytes before it vary.
  The **reference-period / facet** dimension (type `0x0e`, e.g. "Year (2)" in
  tables spanning two censuses) is framed `[type][count][01][01]<name>` — type-
  first with a doubled `0x01` — which the old scan dropped. The type byte is a
  storage/classification tag, **not** a fixed dimension identity (e.g. `0x02` is
  "Statistics" in 98-10-0241 but gender/sex in the family-2 census tables).
- **There is ONE decode pattern — "family 1 / family 2" are two cases of it**
  (`decode.R`, `ivt_layout()` + `ivt_decode()`). Nest **every** dimension
  power-of-two-positionally (`ivt_f2_bit_layout()`), data dimensions innermost
  (descriptor order, last fastest) and **geography outermost**. Each page carries a
  fixed **2048-bit (256-byte) presence record**, filled innermost-first; the same
  nesting describes the in-page bits (bit units) **and** the directory entries
  (8-byte entry units). **Exactly one dimension straddles** the 2048-bit boundary:
  its in-page part (`ipc = floor(2048/inner_block)`) stays in the bitmap, the rest
  becomes `window_count = ceil(count/ipc)` directory-paged windows; every dimension
  *outside* the straddle is positional in the directory (power-of-two-nested entry
  strides, window innermost). The "family" is just **which dimension straddles**:
  - a **data** dimension straddles → geography is pushed fully into the directory,
    one page per (geography, outer-data-coord), a per-geography directory block
    (former "family 1": 98-10-0241 Period straddles, geo stride 512 entries=0x1000;
    98-10-0077 Ages; 98-10-0662 Health, geo stride 16 entries=0x80).
  - the data dims fit ≤2048 bits → **geography itself straddles**: `gpp = 2048 /
    data_bits` geographies share each page's presence record and the directory is a
    flat list of geography-window pages (former "family 2": 98-10-0023 4 geos/page,
    98-10-0129 2/page, 1991 4/page). `ivt_layout()$geo_in_page` is the discriminator.
- Per-page value width/type and value-start come from the marker (`ivt_value_trailer()`):
  trailer 0 when the marker's third byte is `0x00`, else the per-marker family-2
  constant (`0x82`→16, `0x84`→8, `0xa2`→34, `0xa4`→18, …). Some tables realise the
  high-A trailers as a `0xFF` run, others as fixed padding — all land identically.
- A **reference-period / facet** dimension (type `0x0e`, e.g. "Year (2)") is **not**
  geography-folded: in 98-10-0077 *Year* is the **innermost in-page dimension** (the
  value run carries the 2020 then 2015 value consecutively). `ivt_f2_geo_count()`
  (descriptor) gives the true 174 geographies. The legacy `ivt_geography_count()`
  (0x1000 stride) returns 348 here only as an artefact of striding a directory whose
  real per-geography stride is 0x2000; it is used only by the family detector.

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

- **Unified cell decode — DONE.** One `ivt_layout()` + `ivt_decode()` (`decode.R`)
  decodes every table, reproducing the two former decoders **byte-identical** on all
  six reference tables (0241/0077/0662 data-dim straddle, 0023/0129/1991 geography
  straddle). The decoder is fully name/type-agnostic. **Remaining name-tied code:
  the family-1 *metadata* path** — `ivt_read_codebook()` / `IVT_DIMS` is still
  hard-coded to 98-10-0241's dimensions, so 98-10-0077 / 98-10-0662 dimension-member
  *labels* are not populated (their *cells* are exact). The clean fix is to route
  family-1 metadata through the descriptor-driven `ivt_f2_metadata()` (generic
  member labels) while preserving family-1 geography *names*; that would also let
  `ivt_family()` collapse further. The 2048-bit presence cap is assumed constant
  (all six tables use it); a float64 table or a no-straddle table would harden it.
- **Family-2 geography DGUID member-ordering** has a few tail artifacts
  (`ivt_f2_geo_dguids()` first-appearance dedup) — the *cell* decode by member id is
  complete and exact, but a handful of DGUID *labels* near the end can be misordered.
- The older **2016-census `98-400-X` / 2001-2006 "F"-series** products are a
  **different container variant** (e.g. `98-400-X2016019`: descriptor framing the
  current `ivt_f2_descriptor()` misreads as `n_dim=524`, page marker `82 01 _ 00`
  with `b3=0x00` not `0x08`, header dir-pointer not at `@558`). Same lineage
  (`04 00 20 00`, doubled-name descriptors, presence+value pages) but needs a
  variant descriptor parser + marker/header detection; rejected cleanly today.
- **Family-2 geography attributes — DONE.** `ivt_f2_geo_attributes()` decodes all
  11 codebook attributes (name, DGUID, level, type abbr, prov abbr, two geocodes,
  data-quality flag, non-response rate; `GEO_TYPE_DESC`/`DQF_NOTE` decodable but
  not exposed: ~99.8% from long-text block splits). Validated exact vs metadata.
  Remaining niceties: (a) the 2 NA names from special-character truncation
  (`Sambaa K’e`), (b) `GEO_TYPE_DESC`/`DQF_NOTE` to 100% (needs block-finder
  fidelity for long text in the largest group), (c) speed up the ~30 s codebook
  block-scan if it becomes a bottleneck.
- **1991 `1003011` — DONE.** Fully wired into `read_ivt()` via the unified decoder
  (geography straddles, 4 geos/page, int16/int32 pages) + the pre-DGUID inline
  geography codebook (`ivt_f2_geo_inline()`, all 41,859 geographies exact) and
  bilingual Age(110)/Sex(3) labels.
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
