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

`read_ivt()` auto-detects via `ivt_family()`, but **both the cell decode and the
metadata read are now shared** (`ivt_decode()` + `ivt_f2_metadata()` for every
family); `family` only tags provenance and gates the `geo_attributes` option.
Metadata: 98-10-0023's full
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
| `codebook-f2.R` | **the unified codebook** (the `ivt_f2_` prefix is historical — used for every family): member-ordered geography DGUIDs (fast vectorised `2021…` Pascal-string scan, first-appearance dedup); `ivt_f2_geo_simple()` (cheap single-block geography names+DGUIDs for small/family-1 tables, NULL for the chunked large tables) — **schema-driven and content-free**: geography is dimension 1, located by its own `81 02 02 00` doubled-name marker (like every data dim), and its attribute arrays are named by the file's **geography attribute schema** `ivt_f2_geo_schema()` (the stored `GEO_NAME·GEO_TYPE_DESC·…·DGUID·…` field list), so `GEO_NAME`/`DGUID` are addressed **by slot/name**, not by sniffing a `"Canada"` first entry or a `"2021…"` prefix (DGUIDs byte-identical to the legacy scan on 0241/0077; `GEO_NAME` is the canonical short name). Falls back to the content-based `ivt_geo_arrays()` for layouts whose attribute arrays aren't clean `n_geo`-blocks (e.g. 0662); data-dimension member labels `ivt_f2_dim_member_labels(raw, want)` (anchored on the codebook **doubled-name marker** `81 02 02 00` via `ivt_f2_codebook_dim_markers()` + `ivt_f2_marker_labels()`: each dimension's `81 02 02 00`+name header sits right after its EN block, so labels are matched **by name** and taken as that block's trailing `count` records — robust to leading framing records, e.g. 0077 Ages, and to ordinal-less short dims, e.g. the 2-member reference period Year=`2020`/`2015`; the old ordinal-anchored + FR/EN-pair scans remain as fallback); the full **geography attribute table** `ivt_f2_geo_attributes()` (attribute-major growing groups via the DGUID anchor; `group_lo = d0 − 10·G`; per-attribute EN-then-FR slots); `ivt_f2_geo_inline()` the **combined-block reader** for every **schema-absent** layout (1991/2006/2011/2016: `"name (code) [type_abbr] flag [(pct%)]"` blocks; bilingual names; character GEOUIDs incl. dotted census-tract codes and bare 2016 codes) — **marker-anchored**: parses only the geography dimension's `81 02 02 00` marker region (`ivt_f2_geo_marker_region()`), not the whole file; returns NULL for schema'd tables (they have no combined block). `ivt_f2_geo_light()` resolves all families through one entry (combined-block → schema/content single-block → DGUID scan). Metadata-driven entry point `ivt_f2_geographies()` prefers the combined-block reader, else the DGUID attribute table, returns a unified `member_id/geo_name/geo_uid/…` table, validated against the header (`ivt_f2_check_geo_count()`). |
| `read-f2.R`     | **the unified metadata + tidy**: `ivt_f2_metadata()` (descriptor dimensions + member labels + geography names/uids + footnotes, for every family); `ivt_f2_vl_pairs()` + `ivt_f2_dim_name()` (full dimension names from the header Variable List, matched to the descriptor **by count** since display order ≠ storage order); `ivt_f2_dimensions()` (uniform per-dim `name/count/type/is_geography/members`); `ivt_f2_tidy()` (label geography by name/uid + data dims by member names). |
| `codebook.R`    | shared codebook primitives (used by `codebook-f2.R`): `ivt_find_member_blocks()` Pascal-run scanner, `ivt_header_text()` / `ivt_table_info()` identity, `ivt_geo_arrays()` (clean name/DGUID blocks), `ivt_footnotes()` text-run extraction. (The old hard-coded family-1 `IVT_DIMS` / `ivt_read_codebook()` are gone — metadata is now fully descriptor-driven.) |
| `read.R`        | public `read_ivt()`, `ivt_metadata()`, `ivt_tidy()`, `print.ivt` — **one path for all families** (decode via `ivt_decode()`, metadata via `ivt_f2_metadata()`; `family` now only tags provenance and gates the `geo_attributes` option); `ivt_family()` detector + `ivt_is_supported()` gate. |
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
  format and is a **storage-width tag** for the (large) member count — `0x10` (modern
  2021/DGUID family-2 files) and `0x0d` (the 2011 census-tract table) carry a **u16**
  count, `0x08` (the family-1 reference table) a **u8**. The old `type == 0x10` filter
  silently misread 98-10-0241's geography count as 16383; reading 2011's `0x0d` as u8
  misread its 5447 geographies as 21. `ivt_f2_descriptor()` reads u16 for `0x10`/`0x0d`,
  u8 otherwise; `ivt_f2_data_dims()` likewise takes "all dims after the first" rather
  than filtering by type.
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
  straddle). The decoder is fully name/type-agnostic.
- **Unified metadata — DONE.** `read_ivt()` / `ivt_metadata()` now run **one**
  descriptor-driven metadata path (`ivt_f2_metadata()`) for every family; the
  hard-coded `IVT_DIMS` / `ivt_read_codebook()` / `ivt_pick_english_block()` table is
  gone, as is the family-1 branch in `ivt_tidy()` / `print.ivt()` and the separate
  `ivt_f2_read()`. Dimension member labels come from `ivt_f2_dim_member_labels()`,
  anchored on the codebook's per-dimension **doubled-name marker** (`81 02 02 00` +
  name, the same string the header descriptor stores), which sits immediately after
  each dimension's EN member block: `ivt_f2_marker_labels()` matches the marker name
  to a descriptor dimension and takes that block's trailing `count` records (the
  old ordinal-anchored + adjacent-FR/EN-pair scans remain as a fallback). Full
  dimension names from the header Variable List matched to the descriptor **by
  count** (`ivt_f2_vl_pairs()` — display order ≠ storage order in 98-10-0241, and
  the `(3C)`-style flagged count is parsed); geography names+DGUIDs from the cheap
  single-block codebook (`ivt_f2_geo_simple()`, small/family-1 tables) or the fast
  DGUID scan + optional `geo_attributes` (large family-2 tables). `geographies` is
  now uniformly keyed `geo_name`/`geo_uid`/`member_id` for both families (was
  `name`/`dguid` for family 1), and `ivt_tidy()` emits `geo_name`/`geo_uid` columns
  for all tables. **All six reference tables now label every data dimension**,
  byte-identical to the old output where it existed; the marker anchor closed the
  last gaps: 98-10-0077 `Ages`(18) (EN block carries 2 leading framing records) and
  `Year`(2) (a 2-member reference period with no ordinal block, `2020`/`2015`), and
  98-10-0662's two 6-member language dimensions, which share a count and so
  collapsed under the count-keyed store — `ivt_f2_dimensions()` resolves same-count
  dimensions per dimension **by name**. The 2048-bit presence cap is assumed
  constant (all six tables use it); a float64 table or a no-straddle table would
  harden it.
- **Uniform, content-free geography parsing.** Geography is dimension 1 with the same
  `81 02 02 00` doubled-name marker as every data dim; `ivt_f2_geo_light()` resolves
  every family through **one marker-anchored entry**. There are **two storage
  strategies** (not one): the 2021 census tables store geography as **separate
  schema-named arrays** (`ivt_f2_geo_schema()` field list `GEO_NAME·…·DGUID·…`), while
  every **schema-absent** table stores it as the inline combined block `"<name>
  (<code>) [<type_abbr>] <dqf> [(<pct>%)]"`. **DGUIDs are 2021-specific, not "2016+"**
  — the 2016 `98-400-X` tables carry no schema and no DGUID. `ivt_f2_geo_light()`
  order: **combined-block reader** (schema-absent) → **schema/content single-block**
  (2021 small) → **DGUID scan** (2021 chunked); the combined-block reader returns NULL
  for schema'd tables (they have no combined block: e.g. 0241's `Corner Brook (CA),
  N.L.` parens are part of the *name*), so they fall through cleanly.
  - **Schema'd single-block (0241/0077):** `ivt_f2_geo_simple_schema()` reads arrays by
    schema slot/name, no `"2021"`/`"Canada"` sniffing; `GEO_NAME` is the canonical short
    name, DGUID byte-identical to the legacy scan.
  - **Combined-block (1991/2006/2011/2016):** `ivt_f2_geo_inline()` anchors on
    `ivt_f2_geo_marker_region()` and parses **only** that region; name/uid/flag come
    from the block's **structural format**. The uid is **character** — a bare code
    (2016 `01`, 2006 `1001105`), a dotted census-tract code (2011 `0010001.00`), never
    a DGUID here. Admits accented type abbrevs (`MÉ`) and the 2016 trailing `(pct%)`.
    Exact member counts: 1991 41,859 (byte-identical to the former scan), 2006 57,523,
    2011 5,447, 2016 (98-400-X2016387) 174 (single-block; its uid was previously empty).
  - Geography **count** from the descriptor per-type width tag (`0x10`/`0x0d`→u16, else
    u8; 2011's `0x0d` was misread as u8 = 21). 1991's default tidy now labels geography
    by name + GEOUID (was member-id only).
  - **Stage 3 (the last split):** only the **2021 chunked DGUID** tables (0023/0129)
    still resolve their uid via the year-locked `"2021"` byte scan
    (`ivt_f2_geo_dguids()`) and segment 256-member groups by the `"2021…"` anchor +
    hard-coded `IVT_F2_ATTR_SLOTS` (`ivt_f2_geo_attributes()`). Folding these under the
    marker+schema view (chunked schema reader, byte-identical on all 63,404 DGUIDs) is
    the remaining work. The layout appears 2021-specific, so the lock is never
    exercised on another vintage — but it is the one hard-coded remnant left.
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
