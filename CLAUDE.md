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
| `fallback.R`    | **loud fallbacks**: `ivt_fallback(msg, class)` — classed warning (`canivt_fallback` by default) raised whenever a content-heuristic fallback supplies values or pages are skipped; `options(canivt.strict = TRUE)` upgrades to a classed error. `ivt_quietly()` muffles both for speculative probes (family detection). Wire every new fallback path through this. |
| `container.R`   | page-directory anchor `ivt_idx0()` (reads `u16@558`, validates by checking the first entry points at a page marker — works for any file size) + the legacy 0x1000-stride `ivt_geography_count()` (kept only for the family detector / regression). `IVT_IDX0_DEFAULT=37167` is a fallback. |
| `decode.R`      | **the unified cell decoder.** `ivt_layout()` nests every dimension (data innermost, geography outermost), finds the one straddle dim at the 2048-bit page cap, and computes in-page / straddle / paged roles, the in-page bit grid, and the 8-byte directory-entry strides. `ivt_decode()` walks the paged-coordinate cartesian, decodes each page (`ivt_f2_record_present()` + marker-driven value-start `ivt_value_trailer()`) → cell tibble (`geo` + one slug column per data dimension). Handles geography-paged (former family 1) and geography-in-page/multiple-geos-per-page (former family 2) identically. |
| `container-f2.R`| family-2 page-directory finder (used by the metadata path) + per-page value params (`IVT_F2_PAGE_TRAILER` per marker); `ivt_f2_geos_per_page()` / `ivt_f2_geography_count()`. |
| `decode-f2.R`   | shared presence-bitmap primitives used by `ivt_layout()`/`ivt_decode()` for **every** table (the `ivt_f2_` prefix is historical): `ivt_f2_nextpow2()`, `ivt_f2_bit_layout()` (power-of-two-nested strides), `ivt_f2_cell_grid()` (cells in dense value order), `ivt_f2_record_present()` (**byte-pair-swap**, **MSB-first** bit read). |
| `dimdir.R`      | **the header per-dimension directory slot table** — the primary, purely metadata-driven anchor for the whole codebook. Header `@824 + 14·(k−1)` holds a 14-byte record per descriptor dimension `k` (`[u32 dir_ptr][u32 ?][u32 n_entries][2B]`); `ivt_f2_dim_slots()` reads the table, `ivt_f2_dim_dir(raw, k)` resolves dimension `k`'s **block directory** (`[u32 off][u16 len][u16 len]` entries; two indirection depths — the big chunked geo dirs route slot → struct → directory), self-validated against the slot's `n_entries`. Each directory lists that dimension's codebook in logical order: dictionary/schema, member-id table, ordinals, the `81 02 02 00` doubled-name marker, the EN then FR member blocks, then **that dimension's footnotes**. `ivt_f2_dim_dir_labels()` reads every data dimension's labels positionally (marker entry matched to the descriptor name, then the first two member-array entries after it, trailing `count` records, EN via `ivt_f2_frscore()`) — byte-identical to the marker-scan on all 17 data dims of 0241/0077/0023/0129/1991, no tail window; `ivt_f2_dir_footnotes()` reads footnotes **with dimension attribution** (a `dimension` field; sets equal to the tail scan on all five tables). The 1991 legacy format carries the same table. Also home to the two other header directory slots: `ivt_f2_master_dir()` (`@544` → the whole-file **master directory** at offset 992: FACET04 titles, descriptor, EN/FR identity/notes blobs, product id, EOF trailer) and `ivt_f2_dqf_legend()` (`@712` → the **data-quality-flag legend**, `[82 01]`-framed EN/FR records per code A–E/R/P; NULL on the pre-DGUID stub). |
| `codebook-f2.R` | **the unified codebook** (the `ivt_f2_` prefix is historical — used for every family): member-ordered geography DGUIDs (fast vectorised DGUID-shape Pascal-string scan, first-appearance dedup); `ivt_f2_geo_simple()` (cheap single-block geography names+DGUIDs for small/family-1 tables, NULL for the chunked large tables) — **schema-driven and content-free**: geography is dimension 1, located by its own `81 02 02 00` doubled-name marker (like every data dim), and its attribute arrays are named by the file's **geography attribute schema** `ivt_f2_geo_schema()` (the stored `GEO_NAME·GEO_TYPE_DESC·…·DGUID·…` field list), so `GEO_NAME`/`DGUID` are addressed **by slot/name**, not by sniffing a `"Canada"` first entry or a `"2021…"` prefix (DGUIDs byte-identical to the legacy scan on 0241/0077; `GEO_NAME` is the canonical short name). Falls back to the content-based `ivt_geo_arrays()` for layouts whose attribute arrays aren't clean `n_geo`-blocks (e.g. 0662); data-dimension member labels `ivt_f2_dim_member_labels(raw, want)` (anchored on the codebook **doubled-name marker** `81 02 02 00` via `ivt_f2_codebook_dim_markers()` + `ivt_f2_marker_labels()`: each dimension's `81 02 02 00`+name header sits right after its EN block, so labels are matched **by name** and taken as that block's trailing `count` records — robust to leading framing records, e.g. 0077 Ages, and to ordinal-less short dims, e.g. the 2-member reference period Year=`2020`/`2015`; the old ordinal-anchored + FR/EN-pair scans remain as fallback); the geography block directory `ivt_f2_geo_block_dir()` is now **dimension 1's slot directory** (`ivt_f2_dim_dir(raw, 1)`, `dimdir.R`), with the old `IVT_F2_DIR_SLOTS` guess loop as fallback; the full **geography attribute table** `ivt_f2_geo_attributes()` — **directory-driven**: `ivt_f2_geo_attrs_dir()` reads every attribute **positionally** from the file's own metadata block directory (blocks in logical order, per group `[display + schema fields]` × EN-then-FR runs of `G` chunks; group sizes `ivt_f2_geo_group_sizes()`, ordinals dropped `ivt_f2_is_ordinal()`), **no strides / no reverse-root override / no content-located TNR**; entry VALUES come from the **strict block-framing parse** `ivt_f2_dir_entry_members()` (plain `[01 01][u16 payload][u16 n_slots]` arrays: exactly n_slots NUL-terminated records, absent members and the pow-2 slot padding as explicit empty records → NA; dense `[81 01][u16 nbits][u16-padded bitstream][80|01]` arrays: unterminated records skipping absent members, re-aligned from a plain sibling's NA pattern; see ivt-format.md), the run-scanner only classifies entries and supplies fallback values; gated on the regular block count and falling back to the legacy **stride** path (attribute-major growing groups via the DGUID anchor `group_lo = d0 − dguid_slot·2G`; per-attribute EN-then-FR slots; `ivt_f2_geo_root_dir()` root override) only when the directory lists the codebook irregularly (e.g. 98-10-0013 ADA). `DQF_NOTE` is positional where strict-parsed (100% on 0023; the 1-byte record length caps values at 252 bytes — longer notes are truncated in the file itself), with the `ivt_f2_derive_text()` majority-vote filling only scanner-read slots; `ivt_f2_geo_inline()` the **combined-block reader** for every **schema-absent** layout (1991/2006/2011/2016: `"name (code) [type_abbr] flag [(pct%)]"` blocks; bilingual names; character GEOUIDs incl. dotted census-tract codes and bare 2016 codes) — **positional first** (`ivt_f2_geo_inline_dir()`: per group of `G` chunks, `R` directory-ordered runs of `G` chunk blocks; `R` derived from the candidate count and roles detected by content — the two combined runs by `IVT_F2_INLINE_PAT` parse rate, a code array as any other run equal to the parsed codes (uid falls back to the parsed code when absent, e.g. 2006's R=3); chunk record counts validated per run, 2006's partial-first rotation accepted, values strict-first via `ivt_f2_dir_entry_members()` — fixes the silent dedup-scan misorders on 1991/2006/2011, each validated vs the B2020 viewer), falling back to the marker-region block scan (`ivt_f2_geo_marker_region()`, itself bounded by the geography directory's byte span `ivt_f2_geo_dir_span()` when the slot table resolves); returns NULL for schema'd tables (they have no combined block). `ivt_f2_geo_light()` resolves all families through one entry (combined-block → directory-positional attrs read for single-chunk schema'd tables (`ivt_f2_geo_attrs_dir(trim = FALSE)`, byte-identical to `ivt_f2_geo_simple()`, which stays as fallback) → DGUID scan). Metadata-driven entry point `ivt_f2_geographies()` prefers the combined-block reader, else the DGUID attribute table, returns a unified `member_id/geo_name/geo_uid/…` table, validated against the header (`ivt_f2_check_geo_count()`). |
| `read-f2.R`     | **the unified metadata + tidy**: `ivt_f2_metadata()` (descriptor dimensions + member labels + geography names/uids + footnotes, for every family); `ivt_f2_vl_pairs()` + `ivt_f2_dim_name()` (full dimension names from the header Variable List, matched to the descriptor **by count** since display order ≠ storage order); `ivt_f2_dimensions()` (uniform per-dim `name/count/type/is_geography/members`; labels **slot-directory-first** via `ivt_f2_dim_dir_labels()`, marker/count scans only for dims the directories miss); `ivt_f2_footnotes()` (slot-directory footnotes with `dimension` attribution, tail-scan fallback); `ivt_f2_legacy_footnotes()` (the legacy "(N) …" notes, bounded by the master-directory EN blob entry, tail window as fallback); metadata exposes `dqf_legend` (`ivt_f2_dqf_legend()`); `ivt_f2_tidy()` (label geography by name/uid + data dims by member names). |
| `codebook.R`    | shared codebook primitives (used by `codebook-f2.R`/`dimdir.R`): `ivt_find_member_blocks()` Pascal-run scanner, `ivt_header_text()` / `ivt_table_info()` identity, `ivt_geo_arrays()` (clean name/DGUID blocks), `ivt_footnote_texts()` text-run extraction inside a byte window (used per directory entry and by the `ivt_footnotes()` tail-scan fallback). (The old hard-coded family-1 `IVT_DIMS` / `ivt_read_codebook()` are gone — metadata is now fully descriptor-driven.) |
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
- Value run starts at `4 + presence_len + trailer(marker)`
  (`presence_len = rec_bytes × geos_per_page`); the trailer is a **formula, not a
  table** (`ivt_value_trailer()`): `b2 == 0x00` → 0, else `32/width` for `0x8*`
  markers and `64/width + 2` for `0xa*` (reproducing the former per-marker
  constants 4/10/34/18/8/16 exactly; zero violations on ~148k corpus pages).
  Unknown markers **abort** (`canivt_unknown_marker`), and every page is
  extent-checked against its directory entry's u16 size
  (`4 + presence + trailer + nv·width ≤ size`, equality when `b2 == 0`;
  `canivt_page_overrun`). Valid directory entries pointing at unknown markers
  are skipped **loudly** (`canivt_skipped_pages` — 98-400-X2016203 has 369
  undecoded `a2 01 03 0a` pages, values all int16 -1, likely suppression). The
  store keeps only **non-zero** cells (the CSV publishes the zeros), so a
  missing cell = 0; entirely empty geographies (zero presence record) are normal.
- **Fallbacks are LOUD** (`ivt_fallback()`, `fallback.R`): every content-heuristic
  path (stride walk, regex/dedup scans, count-keyed labels, marker-scan directory
  location, fixed slot orders, tail windows) raises a classed `canivt_fallback`
  warning when it supplies values; `options(canivt.strict = TRUE)` upgrades these
  (and skipped pages) to errors. Detection probes stay quiet (`ivt_quietly()`).
  When adding a new fallback path, wire it through `ivt_fallback()` — never let a
  heuristic read engage silently.
- The page-directory entry floor is **1024 (past the header region), not 1e5**:
  the old 100 KB content guess silently truncated small files' directories
  (98-400-X2016387: 6 of 22 pages — its pages start at ~7 KB). A **no-straddle**
  layout (all dims fit one presence record) **aborts** (`canivt_no_straddle`):
  never validated, and the one file that parses that way (2001 F-series
  97F0020XCB2001070) decodes to garbage — this abort is what rejects it.
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
  constant (all six tables use it); a genuine no-straddle table now **aborts**
  (`canivt_no_straddle`, decode.R) rather than run the unvalidated branch — the
  only file that parses that way is the incompatible 2001 F-series variant.
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
    Exact member counts (each viewer-validated; see the member-ordering bullet
    below): 1991 41,859 (the former scan misordered the last 2,435), 2006 57,523
    (R=3 runs, no code array, partial chunk stored first per run; scan misordered
    18,432), 2011 5,447 (scan misordered 1,351), 2016 (98-400-X2016387) 174
    (single-block, an extra leading run; its uid was previously empty).
  - Geography **count** from the descriptor per-type width tag (`0x10`/`0x0d`→u16, else
    u8; 2011's `0x0d` was misread as u8 = 21). 1991's default tidy now labels geography
    by name + GEOUID (was member-id only).
  - **Stage 3 (the last split) — DONE.** The **2021 chunked DGUID** tables
    (0023/0129) are now folded under the marker+schema view, **byte-identical on all
    63,404 DGUIDs and every attribute** (both files). No year literal and no
    hard-coded slot table drive the chunked read: (a) `ivt_f2_geo_slot_map()` reads
    each attribute's slot from the file's own schema field list
    (`ivt_f2_geo_schema()`, now anchored on the header codebook pointer so it is
    readable despite the ~18 MB tail), reproducing the fixed `IVT_F2_ATTR_SLOTS`
    order exactly (kept only as the fallback when a schema is absent); (b)
    `ivt_f2_geo_groups_chunked()` segments the 256-member groups **structurally** —
    the DGUID slot is a contiguous run of `ivt_f2_is_dguid_block()` blocks (2G per
    group, EN then FR), split into runs with **deterministic** member ids from the
    running 256-chunk total (never read from DGUID content); (c) the DGUID column
    itself falls out of its own schema slot (`ivt_f2_extract_attr()` anchors the
    group start on `d0 − dguid_slot·2G`, so the anchor is schema-derived too); and
    (d) `ivt_f2_geo_dguids()` (the fast uid-only scan) hits on the **DGUID shape**
    `<YYYY><level letter>` restricted to the geography marker region, not the literal
    `"2021"`, so it is vintage-agnostic. `IVT_F2_ATTR_SLOTS` remains only as the
    no-schema fallback. The DGUID shape (`IVT_F2_DGUID_RE`, shared by the byte scan
    and the block detector) admits a **dot** in the code so **census-tract DGUIDs**
    (`2021S05079320001.00`) are recognised — without it only the ~50 non-dotted
    higher-level DGUIDs in a CT table were found (this was broken on the old `"2021"`
    path too). Validated beyond 0023/0129 on two more 2021 tables: **98-10-0174**
    (dissemination areas; a **family-1** table carrying the same chunked 63,404-geo
    DGUID codebook — proves the geography reader is family-agnostic) and
    **98-10-0478** (census tracts; 6,297 geos, geography type `0x0d`, chunk groups
    `1,1,2,4,8,9`, all DGUIDs/levels/types/codes exact).
  - **Bilingual geography names (display label + GEO_NAME) — DONE.**
    `ivt_f2_geo_attributes()` emits `geo_label`/`geo_label_fr` (the human-readable
    display **Member Name**, e.g. `0001.00 - Abbotsford - Mission`) and
    `geo_name`/`geo_name_fr` (the schema **GEO_NAME** — a bare code like `9320001.00`
    for census tracts / unnamed DAs). Both are read **structurally from the codebook,
    not inferred from content** (`ivt_f2_geo_names()` + `ivt_f2_geo_name_runs()`): the
    two NAME attributes sit at the front of each group and are anchored on
    `GEO_TYPE_DESC`'s block (`d0 − (dguid_slot−1)·2G`, reliable because type→DGUID
    keep their trailing partials), walking **backward** through the two GEO_NAME runs
    (drop-aware — a code run's lost trailing partial is detected by its last block
    being a full 256 vs the partial size) then the two display runs. Language is
    decided **per group** by `ivt_f2_frscore()` (accents + French connective tokens −
    English tokens over the members where the two runs differ), because the physical
    EN/FR order is EN-first in most groups but **FR-first in the root group** (0023's
    group 1 stores `Terre-Neuve-et-Labrador` before `Newfoundland and Labrador`).
    Validated: `geo_label` == the StatCan "Member Name" column **63,404/63,404** on
    0023, **6,297/6,297** on 0478, and cross-checks 63,404/63,404 between 0023 and 0174
    (same DA universe). `ivt_tidy()` / `geographies` front `geo_label` before
    `geo_name`. The old `group1_name` GEO_NAME hack in `ivt_f2_extract_attr()` (slot 0
    only) is superseded; the other attributes (slots ≥1) still use the fixed
    `d0 − (dguid_slot−slot)·2G` stride, which is correct even under a GEO_NAME partial
    drop since the drop is entirely within slot 0. Known nicety on 0478: the last
    group's GEO_NAME (code) loses its trailing 153-member partial to the block scanner
    (special bytes after the short block) → those 153 `geo_name` codes are NA;
    `geo_label` (text, keeps its partial) and every other attribute are complete.
  - **Trailing-partial drop + off-window schema (98-10-0013 ADA) — DONE.** Two
    hard-coded heuristics failed this table. (a) `ivt_f2_codebook_blocks`'s
    `length ≥ 150` floor dropped the last group's **71-member trailing partial**,
    undercounting geography 5,376/5,447. The floor is now structural: a small clean
    member-array block is kept **only when it immediately follows a full member
    block** (a partial trails its own full chunks); garbage byte-runs cluster alone
    and are still dropped. All 5,447 DGUIDs decode; 0023/0478 stay byte-identical.
    (b) `ivt_f2_geo_schema` called ADA's schema "absent" — it isn't; the attribute
    dictionary sits ~14 KB *before* the codebook pointer, outside the old
    `[cb−8000, EOF]` half-window. The dictionary block is now located by **following
    the file's own metadata directory**: a header slot (`@824` on the small chunked
    tables indexes the geography codebook blocks; also `@572`/`@712`) holds a table of
    `[u32 off][u16 len][u16 len]` entries — the same entry shape as the page directory
    — which `ivt_f2_geo_dict_block()` / `ivt_f2_read_block_dir()` decode, confirming
    the block by its `GEO_NAME_EN` field name (so a slot meaning something else on a
    given file is skipped). The dictionary start thus comes **from the file, not a
    scan**, on **every** table now (`ivt_f2_geo_block_dir()` tries two indirection
    depths per slot: the slot value is the directory itself on the small chunked
    tables 0013/0478/0241, but a small geography-dimension struct whose first u32 is
    the directory pointer on the big tail-codebook tables 0023/0174 — `@824 → struct →
    ptr1 → directory`, 6,244 entries on 0023, 6,758 on 0174). The `cb ± 128 KB` centred
    window survives only as a last-ditch fallback for a layout that exposes no directory.
  - **Reverse-stored root chunk, read positionally from the block directory
    (98-10-0013 ADA root group) — DONE.** The codebook's first ("root") chunk is stored
    in **reverse byte order** (region A of the tail: directory offsets *decrease*
    through it, then jump up for the bulk). The byte-ascending block scan
    `ivt_f2_codebook_blocks()` / `ivt_f2_geo_groups_chunked()` therefore reverses that
    chunk's logical block order, and because ADA's root chunk also carries extra framing
    blocks the stride walk lands wrong — leaving `geo_label`/`geo_name`/`geo_type`/
    `geo_level`/`geo_type_abbr` **NA** for members 1–256 *and* **scrambling**
    `prov_abbr`/`alt_geo_code`/`pr_code` (they read codes / French type text). ADA read
    5,191/5,447. Fix: read the root chunk **positionally from the header block
    directory** — the `@824` slot is a table of `[u32 off][u16 len][u16 len]` entries
    (the block **offsets and lengths**, same entry shape as the page directory), and
    within a group the value blocks are laid down in a fixed sequence — the display
    Member Name pair, then every schema field in **schema order**, each EN then FR. So
    `ivt_f2_geo_root_dir()` reads the value blocks (record count == chunk size `rootN`)
    in directory order, pairs them, and maps pair 1 → display name, pair k+1 →
    `ivt_f2_geo_schema()[k]` (language per pair by `ivt_f2_frscore()`). **No marker, no
    content sniffing, no `d0 ± k·2G` stride** — block starts come from the header
    directory, field identity from the schema position. `ivt_f2_geo_attributes()`
    overrides members 1..rootN with this read. Validated: ADA every root attribute
    exact (`geo_label` == "Member Name" **5,447/5,447**, `geo_type` Country/Province/
    ADA, `prov_abbr`/`pr_code`/`alt_geo_code` correct); the positional read matches the
    stride output **256/256 on every attribute** on 98-10-0478 CT **and on both big
    tables 0023/0174** (whose directory now resolves via the extra indirection), so the
    override is byte-identical there (unchanged 63,404/63,404).
  - **Drive *all* groups from the directory's block order — DONE.** `ivt_f2_geo_attrs_dir()`
    is now the **primary** chunked-geography reader (`ivt_f2_geo_attributes()` tries it
    first, falling back to the stride path only when the directory is absent or lists the
    codebook irregularly). It reads every attribute **positionally** from the block
    directory — no `d0 ± k·2G` strides, no byte-ascending block scan (so the reverse-root
    chunk needs no override), no content-located TNR. Value blocks in directory order are,
    per group of `G` chunks, `[display Member Name, then every schema field]` each as an EN
    run (chunks 0..G-1) then FR run = `2G` blocks/attribute; group chunk-sizes from
    `ivt_f2_geo_group_sizes(n_geo)` (1,1,2,4,8,… last trimmed), ordinal blocks skipped via
    `ivt_f2_is_ordinal()`. The self-consistency gate is the regular block count
    `2·(nfield+1)·Σsizes` (`5,952 = 24·248` on 0023); if it fails (a dropped trailing
    partial, e.g. 98-10-0013 ADA) the function returns NULL → stride fallback. `DQF_NOTE`
    keeps the `ivt_f2_derive_text()` majority-vote from `DQF_CODE` (its long text doesn't
    map to member boundaries); **every other attribute is exact by position.** Validated
    **byte-identical to the stride path on 98-10-0023** (all 63,404 × 15 columns) and it
    **fixes latent stride slot bugs** on tables carrying the extra `TNR_LONG_FORM` schema
    field: on **98-10-0478** `pr_code`/`dqf_code`/`tnr_short_form` are now exact vs the
    StatCan metadata (stride was wrong for 1,278/327/1,897 members); on **98-10-0129**
    `tnr_short_form` is exact (stride root-override was wrong for 237). Residual (unchanged,
    pre-existing): 0478's last-group code partials (`geo_name`/`alt_geo_code`, 153 members)
    stay NA — the block scanner fragments that code chunk.
- **Geography member-ordering tail artifacts — FIXED.** The byte-ascending scans
  with first-appearance dedup misorder chunks stored out of byte order: the
  positional directory read (`ivt_f2_geo_inline_dir()`) exposed silent misorders
  of **2,435/41,859 (1991), 18,432/57,523 (2006), 1,351/5,447 (2011)** members —
  each validated exact against the B2020 viewer's geography member list (the
  `d0` option order is the definitive member-order ground truth; scrape it via
  `ivt_gt_viewer_url()`). The modern `ivt_f2_geo_dguids()` scan is validated
  equal to the positional `ivt_f2_geo_attrs_dir()` DGUIDs on 0023 and 0129 (0
  mismatches), and its marker-region bound is now the geography directory's byte
  span.
- The older **2016-census `98-400-X` / 2001-2006 "F"-series** products are a
  **different container variant** (e.g. `98-400-X2016019`: descriptor framing the
  current `ivt_f2_descriptor()` misreads as `n_dim=524`, page marker `82 01 _ 00`
  with `b3=0x00` not `0x08`, header dir-pointer not at `@558`). Same lineage
  (`04 00 20 00`, doubled-name descriptors, presence+value pages) but needs a
  variant descriptor parser + marker/header detection; rejected cleanly today
  (2016019 via `ivt_f2_decodable()`, the 2001 `97F0020X` via the no-straddle
  abort). Two 98-400-X files DO pass detection: **98-400-X2016387** (geography
  validated, directory complete after the entry-floor fix) and **98-400-X2016203**
  (decodes but is only partially supported: 369 `b3=0x0a` pages skipped loudly,
  labels + inline geography via warned fallbacks, cells never ground-truthed).
- **Family-2 geography attributes — DONE, positional-exact.** The strict
  value-entry parse (`ivt_f2_dir_entry_members()`, see ivt-format.md "Value-entry
  block framings": plain `[01 01][u16 payload][u16 n_slots]` arrays with explicit
  empty records incl. pow-2 slot padding; dense `[81 01][u16 nbits][bitstream]
  [80|01]` arrays that skip absent members, re-aligned from a plain sibling's NA
  pattern) supplies the values; the run-scanner only classifies entries. Every
  attribute validates exact vs the StatCan metadata CSVs on 0662 (91/91 × 11 —
  its aggregate member 26 has NO attributes; the scanner had shifted every uid
  after member 25), 0023 (63,404 × 11 incl. **DQF_NOTE 100%**, was ~99.8%), 0129,
  0478 (incl. the formerly-NA 153 code partials) and 0013 (stride fallback).
  Remaining: (a) DQF_NOTE texts > 252 chars are stored truncated **in the file**
  (the 1-byte record length caps at `0xFC`) — 2,448 members on 0129, 90 on 0478;
  (b) the dense arrays' bitstream per-member coding is undecoded (not needed —
  alignment comes from the plain siblings); (c) speed up the ~20 s big-table
  codebook read if it becomes a bottleneck.
- **1991 `1003011` — DONE.** Fully wired into `read_ivt()` via the unified decoder
  (geography straddles, 4 geos/page, int16/int32 pages) + the pre-DGUID inline
  geography codebook (`ivt_f2_geo_inline()`, now positional via
  `ivt_f2_geo_inline_dir()`; all 41,859 geographies exact vs the B2020 viewer's
  member list, names and codes) and bilingual Age(110)/Sex(3) labels.
- **Footnotes — dimension-attributed (via `dimdir.R`).** Each footnote is stored
  as an entry of its owning dimension's slot directory, so `ivt_f2_footnotes()`
  emits a `dimension` field (texts set-equal to the old tail scan on all five
  local reference tables; the scan survives as fallback). Remaining nicety:
  per-*member* attribution — the small records preceding each footnote pair in
  the directory look like member references (unverified).
- **Metadata-driven consolidation follow-ups.** DONE: (a) the DGUID scan /
  `ivt_f2_geo_marker_region()` are bounded by the geography directory's byte
  span (`ivt_f2_geo_dir_span()`, dimdir.R; codebook-pointer marker walk kept as
  fallback); (b) the 1991-style inline geography is read **positionally** from
  its directory (`ivt_f2_geo_inline_dir()`: per group of `G` chunks four runs
  [combined lang A, combined lang B, name array, code array], record counts
  validated per chunk, uid = code array cross-checked against the combined
  block's parsed code; the separate name array is **accent-stripped**, so the
  display name still comes from the combined block) — this fixed a 2,435-member
  tail misorder the regex+dedup fallback silently produced; (c)
  `ivt_f2_geo_light()` reads single-chunk schema'd tables (0241/0077) via
  `ivt_f2_geo_attrs_dir(trim = FALSE)` (byte-identical; `ivt_f2_geo_simple()`
  stays as the fallback for irregular layouts); (d) the **master directory at
  offset 992** (`ivt_f2_master_dir()`, slot `@544`; ~10 stable entries: FACET04
  titles EN/FR, the descriptor, the EN/FR identity/notes blobs, product id, EOF
  trailer) now bounds `ivt_f2_legacy_footnotes()` (the EN blob entry matched to
  the `@48` title pointer; 200 KB tail window as fallback), and the **`@712` DQF
  legend** is decoded (`ivt_f2_dqf_legend()`: `[82 01]`-framed EN/FR records per
  code A–E/R/P) and exposed as `dqf_legend` on `ivt_metadata()` (NULL on
  pre-DGUID tables, which carry a stub).
- Optional: expose the per-dimension `depth` directly on `ivt_tidy()` output.
- Consider an `Rcpp` fast path only if pure-R decode becomes a bottleneck (it is
  fine at ~5 s for the reference table).

## Provenance

The IVT format was reverse-engineered in a separate repo
(`~/projects/censusmapper-import`, Python reference decoders `python/ivt2021.py`
and `python/ivt2021_codebook.py`). `canivt` is the standalone R port; it does not
depend on that repo at runtime.
