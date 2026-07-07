# CLAUDE.md — canivt

Guidance for working on **canivt**, an R package that downloads and parses
StatCan *Beyond 20/20* `.ivt` tables into tidy data / Parquet / CSV, and extracts
their metadata (dimension members, geographic identifiers/DGUIDs, footnotes).

This folder is self-contained. Companion docs under `inst/notes/`:

- [`ivt-format.md`](inst/notes/ivt-format.md) — the authoritative byte-format
  reference. **Read it before changing the parser.** (User-facing version: the
  vignette `vignettes/ivt-format.Rmd`.)
- [`coverage.md`](inst/notes/coverage.md) — the **living completeness tracker**
  (what we decode vs what's left, measured byte coverage). **Update it whenever a
  gap is closed or a new one is found.**
- [`decode-history.md`](inst/notes/decode-history.md) — the **narrative changelog**:
  how each table/vintage was cracked, per-table validation records, and the
  derivations behind the key invariants. Not needed day-to-day; consult it for the
  *why* behind a rule.

## What works today

**Every `.ivt` in the local corpus decodes — there are no unsupported files.**
A single, descriptor-driven, name/type-agnostic decoder (`decode.R`:
`ivt_layout()` + `ivt_decode()`) handles all of them, plus one shared metadata
path (`ivt_f2_metadata()`). The historical "family 1 / family 2" split is **not
two formats** — it is one power-of-two-nested positional layout differing only in
*which dimension straddles the 2048-bit page boundary* (see "Key invariants").
Geography is dimension 1 *structurally* (except the profile lineage, geography-
last), the straddle/paging derives from member counts and the 2048-bit cap, and
labels come from the codebook at `tidy` time. Whole-file pure-R decode of the
7.5M-cell reference table runs in ~4–5 s.

Validated **cell-exact (byte-identical to the two former decoders)** on the six
reference tables (0241/0077/0662 data-dim straddle; 0023/0129/1991 geography
straddle), and viewer/CSV-validated across the wider corpus — 1996–2021 census
tables, 1981/1991 profiles, 2001/2006 F-series, large 2016 `98-400-X` crosstabs,
and custom cro/ord extracts. Per-table validation records and the story of how
each was cracked live in [`decode-history.md`](inst/notes/decode-history.md); the
measured coverage lives in [`coverage.md`](inst/notes/coverage.md).

Key semantics to know:

- **The store keeps only non-zero cells** (the CSV publishes the zeros), so an
  absent cell is a zero *within a geography that carries data*. **Suppression is
  whole-geography**: a geography with NO stored cells is wholly suppressed or
  wholly empty — `read_ivt()` exposes `metadata$geographies$has_data` (presence-
  derived), and on inline pre-DGUID tables `dqf_code` corroborates it. There is no
  per-cell sentinel.
- **Geography metadata is on the DEFAULT path**: `metadata$geographies` packs
  every decoded per-member column (bilingual `geo_label`/`geo_name`, `geo_uid`
  (DGUID or bare GEOUID), level/type, geocodes, `dqf_code`, `tnr_short_form`;
  all-NA columns dropped). `read_ivt(geo_attributes = TRUE)` additionally decodes
  the full attribute table for the large chunked family-2 tables (~30 s block-scan).
- `read_ivt()` auto-detects via `ivt_family()`, but the cell decode and metadata
  read are **shared for every family**; `family` only tags provenance and gates
  the `geo_attributes` option.

## Code map (`R/`)

| file | role |
|------|------|
| `utils-bytes.R` | low-level readers: `rd_u16/rd_u32/rd_int_run/rd_pascal`; latin-1 decode. **All offsets are 0-based** (binary layout); helpers convert to R's 1-based indexing. |
| `fallback.R`    | **loud fallbacks**: `ivt_fallback(msg, class)` — classed warning (`canivt_fallback` by default) raised whenever a content-heuristic fallback supplies values or pages are skipped; `options(canivt.strict = TRUE)` upgrades to a classed error. `ivt_quietly()` muffles both for speculative probes (family detection). Wire every new fallback path through this. |
| `container.R`   | page-directory anchor `ivt_idx0()` (reads `u16@558`, validates by checking the first entry points at a page marker — works for any file size) + the legacy 0x1000-stride `ivt_geography_count()` (kept only for the family detector / regression). `IVT_IDX0_DEFAULT=37167` is a fallback. |
| `decode.R`      | **the unified cell decoder.** `ivt_layout()` nests every dimension (data innermost, geography outermost), finds the one straddle dim at the 2048-bit page cap, and computes in-page / straddle / paged roles, the in-page bit grid, and the 8-byte directory-entry strides. `ivt_decode()` walks the paged-coordinate cartesian, decodes each page (`ivt_f2_record_present()` + marker-driven value-start `ivt_value_trailer()`) → cell tibble (`geo` + one slug column per data dimension). Handles geography-paged (former family 1) and geography-in-page/multiple-geos-per-page (former family 2) identically. |
| `container-f2.R`| family-2 page-directory finder (used by the metadata path) + the marker byte model (`ivt_f2_is_marker()`: `b0` width/variant nibbles, `b3 ∈ {08,09,0a,0c}` head-block codes); `ivt_f2_geos_per_page()` / `ivt_f2_geography_count()`. |
| `decode-f2.R`   | shared presence-bitmap primitives used by `ivt_layout()`/`ivt_decode()` for **every** table (the `ivt_f2_` prefix is historical): `ivt_f2_nextpow2()`, `ivt_f2_bit_layout()` (power-of-two-nested strides), `ivt_f2_cell_grid()` (cells in dense value order), `ivt_f2_record_present()` (**byte-pair-swap**, **MSB-first** bit read). |
| `dimdir.R`      | **Bilingual labels + dimension names** are read here: `ivt_f2_dim_dir_label1()` returns `list(en, fr, name_fr)` per dimension — EN vs FR chosen by a **structural marker** (`ivt_f2_dim_dict_en_first()`: the dimension's dictionary/schema block names `English Desc` before `Desc Français`/`Desc fran`, and the two member blocks follow that schema order), with `ivt_f2_frscore()` only as the loud fallback when the schema block is absent. The **French dimension name** (`ivt_f2_total_name()`) is the French `Total - <name>` first member (the header Variable List is English-only), NA for Statistics-type dims. **the header per-dimension directory slot table** — the primary, purely metadata-driven anchor for the whole codebook. Header `@824 + 14·(k−1)` holds a 14-byte record per descriptor dimension `k` (`[u32 dir_ptr][u32 ?][u32 n_entries][2B]`); `ivt_f2_dim_slots()` reads the table, `ivt_f2_dim_dir(raw, k)` resolves dimension `k`'s **block directory** (`[u32 off][u16 len][u16 len]` entries; two indirection depths — the big chunked geo dirs route slot → struct → directory), self-validated against the slot's `n_entries`. Each directory lists that dimension's codebook in logical order: dictionary/schema, member-id table, ordinals, the `81 02 02 00` doubled-name marker, the EN then FR member blocks, then **that dimension's footnotes**. `ivt_f2_dim_dir_labels()` reads every data dimension's labels positionally (marker entry matched to the descriptor name, then the first two member-array entries after it, trailing `count` records, EN via `ivt_f2_frscore()`) — byte-identical to the marker-scan on all 17 data dims of 0241/0077/0023/0129/1991, no tail window; `ivt_f2_dir_footnotes()` reads footnotes **with dimension attribution** (a `dimension` field; sets equal to the tail scan on all five tables). The 1991 legacy format carries the same table. Also home to the two other header directory slots: `ivt_f2_master_dir()` (`@544` → the whole-file **master directory** at offset 992: FACET04 titles, descriptor, EN/FR identity/notes blobs, product id, EOF trailer) and `ivt_f2_dqf_legend()` (`@712` → the **data-quality-flag legend**, `[82 01]`-framed EN/FR records per code A–E/R/P; NULL on the pre-DGUID stub). |
| `codebook-f2.R` | **the unified codebook** (the `ivt_f2_` prefix is historical — used for every family): member-ordered geography DGUIDs (fast vectorised DGUID-shape Pascal-string scan, first-appearance dedup); `ivt_f2_geo_simple()` (cheap single-block geography names+DGUIDs for small/family-1 tables, NULL for the chunked large tables) — **schema-driven and content-free**: geography is dimension 1, located by its own `81 02 02 00` doubled-name marker (like every data dim), and its attribute arrays are named by the file's **geography attribute schema** `ivt_f2_geo_schema()` (the stored `GEO_NAME·GEO_TYPE_DESC·…·DGUID·…` field list), so `GEO_NAME`/`DGUID` are addressed **by slot/name**, not by sniffing a `"Canada"` first entry or a `"2021…"` prefix (DGUIDs byte-identical to the legacy scan on 0241/0077; `GEO_NAME` is the canonical short name). Falls back to the content-based `ivt_geo_arrays()` for layouts whose attribute arrays aren't clean `n_geo`-blocks (e.g. 0662); data-dimension member labels `ivt_f2_dim_member_labels(raw, want)` (anchored on the codebook **doubled-name marker** `81 02 02 00` via `ivt_f2_codebook_dim_markers()` + `ivt_f2_marker_labels()`: each dimension's `81 02 02 00`+name header sits right after its EN block, so labels are matched **by name** and taken as that block's trailing `count` records — robust to leading framing records, e.g. 0077 Ages, and to ordinal-less short dims, e.g. the 2-member reference period Year=`2020`/`2015`; the old ordinal-anchored + FR/EN-pair scans remain as fallback); the geography block directory `ivt_f2_geo_block_dir()` is now **dimension 1's slot directory** (`ivt_f2_dim_dir(raw, 1)`, `dimdir.R`), with the old `IVT_F2_DIR_SLOTS` guess loop as fallback; the full **geography attribute table** `ivt_f2_geo_attributes()` — **directory-driven**: `ivt_f2_geo_attrs_dir()` reads every attribute **positionally** from the file's own metadata block directory (blocks in logical order, per group `[display + schema fields]` × EN-then-FR runs of `G` chunks; group sizes `ivt_f2_geo_group_sizes()`, ordinals dropped `ivt_f2_is_ordinal()`), **no strides / no reverse-root override / no content-located TNR**; entry VALUES come from the **strict block-framing parse** `ivt_f2_dir_entry_members()` (plain `[01 01][u16 payload][u16 n_slots]` arrays: exactly n_slots NUL-terminated records, absent members and the pow-2 slot padding as explicit empty records → NA; dense `[81 01][u16 nbits][u16-padded bitstream][80|01]` arrays: unterminated records skipping absent members, re-aligned from a plain sibling's NA pattern; see ivt-format.md), the run-scanner only classifies entries and supplies fallback values; gated on the regular block count and falling back to the legacy **stride** path (attribute-major growing groups via the DGUID anchor `group_lo = d0 − dguid_slot·2G`; per-attribute EN-then-FR slots; `ivt_f2_geo_root_dir()` root override) only when the directory lists the codebook irregularly (e.g. 98-10-0013 ADA). `DQF_NOTE` is positional where strict-parsed (100% on 0023; the 1-byte record length caps values at 252 bytes — longer notes are truncated in the file itself), with the `ivt_f2_derive_text()` majority-vote filling only scanner-read slots; `ivt_f2_geo_inline()` the **combined-block reader** for every **schema-absent** layout (1991/2006/2011/2016: `"name (code) [type_abbr] flag [(pct%)]"` blocks; bilingual names; character GEOUIDs incl. dotted census-tract codes and bare 2016 codes) — **positional first** (`ivt_f2_geo_inline_dir()`: per group of `G` chunks, `R` directory-ordered runs of `G` chunk blocks; `R` derived from the candidate count and roles detected by content — the two combined runs by `IVT_F2_INLINE_PAT` parse rate, a code array as any other run equal to the parsed codes (uid falls back to the parsed code when absent, e.g. 2006's R=3); chunk record counts validated per run, 2006's partial-first rotation accepted, values strict-first via `ivt_f2_dir_entry_members()` — fixes the silent dedup-scan misorders on 1991/2006/2011, each validated vs the B2020 viewer), falling back to the marker-region block scan (`ivt_f2_geo_marker_region()`, itself bounded by the geography directory's byte span `ivt_f2_geo_dir_span()` when the slot table resolves); returns NULL for schema'd tables (they have no combined block). `ivt_f2_geo_light()` resolves all families through one entry (combined-block → directory-positional attrs read for single-chunk schema'd tables (`ivt_f2_geo_attrs_dir(trim = FALSE)`, byte-identical to `ivt_f2_geo_simple()`, which stays as fallback) → uid-only **positional** read `ivt_f2_geo_dguids_dir()`: an O(1) header+first-record probe finds the DGUID slot's blocks in the geography block directory (plain `[01 01]` or dense `[81 01]` headers; no other attribute stores DGUID-shaped strings), strict-parses only those, and consumes them per group as two language runs of `G` chunks that must agree record-for-record — fixes 98-10-0013's scan-dropped root chunk (members 1–256: the reverse-stored root sits below the marker region, 5,191/5,447 silently) and is 5–13× faster than the byte scan on the 63k-geo tables; the scan survives as the loud fallback via `ivt_f2_geo_uids()`). Metadata-driven entry point `ivt_f2_geographies()` prefers the combined-block reader, else the DGUID attribute table, returns a unified `member_id/geo_name/geo_uid/…` table, validated against the header (`ivt_f2_check_geo_count()`). |
| `read-f2.R`     | **the unified metadata + tidy**: `ivt_f2_metadata()` (descriptor dimensions + member labels + geography names/uids + footnotes, for every family); `ivt_f2_vl_pairs()` + `ivt_f2_dim_name()` (full dimension names from the header Variable List, matched to the descriptor **by count** since display order ≠ storage order); `ivt_f2_dimensions()` (uniform per-dim `name/count/type/is_geography/members`; labels **slot-directory-first** via `ivt_f2_dim_dir_labels()`, marker/count scans only for dims the directories miss); `ivt_f2_footnotes()` (slot-directory footnotes with `dimension` attribution, tail-scan fallback); `ivt_f2_legacy_footnotes()` (the legacy "(N) …" notes, bounded by the master-directory EN blob entry, tail window as fallback); metadata exposes `dqf_legend` (`ivt_f2_dqf_legend()`); `ivt_f2_tidy()` (label geography by name/uid + data dims by member names). |
| `codebook.R`    | shared codebook primitives (used by `codebook-f2.R`/`dimdir.R`): `ivt_find_member_blocks()` Pascal-run scanner, `ivt_header_text()` / `ivt_table_info()` identity, `ivt_geo_arrays()` (clean name/DGUID blocks), `ivt_footnote_texts()` text-run extraction inside a byte window (used per directory entry and by the `ivt_footnotes()` tail-scan fallback). (The old hard-coded family-1 `IVT_DIMS` / `ivt_read_codebook()` are gone — metadata is now fully descriptor-driven.) |
| `read.R`        | public `read_ivt()`, `ivt_metadata()`, `ivt_tidy()`, `print.ivt` — **one path for all families** (decode via `ivt_decode()`, metadata via `ivt_f2_metadata()`; `family` now only tags provenance and gates the `geo_attributes` option); `ivt_family()` detector + `ivt_is_supported()` gate. `ivt_tidy(dim_names=)` names data columns by the terse structural **slug** (`"slug"`, **default** — e.g. `age`, compact + language-neutral) or the **full dimension label** (`"label"` — e.g. `Age of primary household maintainer`); `x$cells` always keeps slugs (the decoder stays name-agnostic), the naming is an output-layer choice (`ivt_data_colnames()`, read-f2.R) shared by `ivt_tidy()`/`ivt_members()` so parquet + sidecar agree. `ivt_tidy(language=)` outputs **English (`"en"`, default) or French (`"fr"`)** member labels + label-derived column names (`ivt_norm_lang()` normalises `en`/`eng`/`fr`/`fra`/… lower-case); French falls back to English per-column where the file carries no French copy (geo_uid, Statistics). Both thread through `ivt_write_parquet()`/`ivt_write_csv()`/`get_statcan_ivt()`/`collect_ivt()`. **Parquet paths carry a language marker** (`<key>_en.parquet` / `<key>_fr.parquet`, so both coexist); `ivt_members_path()` strips it so one **shared** `_members.parquet` sidecar (carrying `level`+`level_fr`+`dimension`+`dimension_fr`) serves both. `ivt_parquet_language(x)` reads the marker off a path/connection; **`label_ivt_columns(x, language=)`** renames slug→full-label on an Arrow connection (lazy `dplyr::rename`) / data frame, language auto-detected from the path. `collect_ivt()`/`label_ivt_columns()` auto-detect language (NULL→marker); `collect_ivt(language="fr")` factors on `level_fr`. Geography columns keep their `geo_*` names (French *content* in fr mode); `geo_uid` is language-neutral. **Slugs (`ivt_dim_slug()`, codebook-f2.R) are generic** — lower-cased leading word of the dimension's metadata name, made unique; no per-table hard-coding. |
| `collect.R`     | **factor-level context**: `ivt_members(x)` — one row per (tidy column, member) with `member_id`/`ordinal`/`label`/`level`/`depth`, for the data dims *and* the geography columns; `collect_ivt(x, members, geography)` — collect an `ivt` object / Arrow dataset / dplyr-on-Arrow query / parquet path and convert dimension columns to **factors whose levels are the FULL member list in ordinal order** (filtered-out members stay visible as levels; the compact `labels = FALSE` id table is mapped through `member_id`; geography conversion opt-in — huge level sets). Member levels travel as a `<name>_members.parquet` **sidecar** written by `ivt_write_parquet()` and attached by `get_statcan_ivt()` (`attr(ds, "members")`); `ivt_locate_members()` walks `$.data` down a dplyr query to the source dataset. Ordinals come from `ivt_f2_dim_dir_ordinals()` (dimdir.R): each data dimension's `1..n` member-ordinal block read positionally from its slot directory (a candidate must be a **permutation of `1..count`**, which rejects numeric label blocks like the reference-period years; a dimension without an ordinal block, e.g. Year(2), is ordered by member id) — stored as `ordinal` on each `ivt_metadata()` dimension. Identity `1..n` on every validated table (0241, 1991). |
| `catalogue.R`   | scrapes the StatCan census datasets index (`https://www12.statcan.gc.ca/datasets/Index-eng.cfm?Temporal=<year>`) into a product catalogue. `statcan_ivt_years()` reads the `Temporal` selector; `statcan_ivt_catalogue()` scrapes every version into a tibble (census_year/catalogue/date/topic/title/pid/ivt_url/download_url/http_url), cached as Parquet in the data cache. `statcan_ivt_resolve_url()` forwards an `Alternative.cfm?PID=` link to its direct `Download.cfm?PID=` URL (b2020 `.zip` URLs returned unchanged). Needs `rvest`+`xml2`. |
| `get.R`         | `get_statcan_ivt(catalogue)` — one-stop accessor: resolves a catalogue number via the catalogue **or** a custom identifier matching a local `.ivt` in the ivt cache, downloads (`statcan_ivt_download()` sniffs zip vs raw IVT), decodes, caches the tidy Parquet (path `<key>_<lang>.parquet`), returns an `arrow::open_dataset()` connection (path on `attr(.,"path")`, member levels on `attr(.,"members")` for `collect_ivt()`). Second call skips download+decode. **`list_ivt_cache()`** enumerates the ivt cache's `.ivt` files (key = per-table folder) and the data cache's tidy Parquets (`<key>_en/_fr.parquet`; excludes `_members` sidecars + the catalogue cache), one row each with `kind`/`key`/`language`/`bytes`/`modified`/`path`, enriched with `catalogue`/`title`/`census_year`/`topic` from the **cached** catalogue (`ivt_cached_catalogue()`, no scrape) matched by normalised key (exact then prefix). **`prune_ivt_cache(x, kind, language, sidecars, dry_run)`** deletes cache files — `x` is catalogue numbers/keys (matched via `ivt_cache_match()`), or a **filtered `list_ivt_cache()` tibble** (uses its `path`), or NULL (all); `kind`/`language` filter; removes a `<key>_members.parquet` sidecar once no Parquet references it and cleans emptied `.ivt` folders (never the catalogue cache or the ivt-cache root); `dry_run` previews. |
| `ground-truth.R` | **internal, not exported** — scrapes the public Beyond 20/20 HTML viewer (`Rp-eng.cfm`, reached by following the catalogue `http_url`'s `URLRedirect`) to build decoder validation fixtures. `ivt_gt_viewer_url()` resolves the viewer (httr2 GET, not HEAD — `URLRedirect.cfm` 302s HEADs to a 404); `ivt_gt_slice(url, gid, fixed)` fetches one pivot slice (state driven by GET params via `ivt_gt_set_params()`, which **replaces** keys — duplicate `GID`/`dN` 404s); `ivt_ground_truth(catalogue, max_geos)` loops geographies. The parser keys off stable markup (`table#tabulation`, `select#d0[name=GID]`, cell `title="[Row N: …] [Column M: …]"`); it returns one row per cell with a `value` plus, per dimension, a slug label column + 1-based `<slug>_id` position (the **position** is the label-independent join key, since HTML slugs `single`/`sex` differ from the decoder's `age`/`gender`). Validated: 1991 decode matches scrape **660/660** for Canada+NL. |
| `cache.R`       | `ivt_cache_dir("ivt"\|"data")` resolves the two optional cache dirs (options `canivt.ivt_cache` / `canivt.data_cache`, falling back to `tempdir()`); `ivt_cache_is_set()`. |
| `zzz.R`         | `.onLoad` seeds the cache options from `CANIVT_IVT_CACHE` / `CANIVT_DATA_CACHE` env vars (so they can live in `.Renviron`) without overriding set options; `.onAttach` warns once if `canivt.data_cache` is unset. |
| `download.R`    | `ivt_download()` from the b2020 endpoint (defaults `dest_dir` to the ivt cache); `ivt_pid8()`. |
| `write.R`       | `ivt_write_parquet()/_csv()/_metadata()` (parquet also writes the `_members.parquet` level sidecar, `members = FALSE` to skip; the metadata CSV carries `ordinal`); `ivt_label_depth()`. |
| `canivt-package.R` | `ivt_read_table()` one-shot wrapper + package doc. |

## Key invariants (don't regress)

The *rules*; the measurements and original bugs behind them are in
[`decode-history.md`](inst/notes/decode-history.md) ("Invariant derivations").

- Index stride is **`0x1000`**, giving **166** geographies in metadata member
  order (directory `n` → Member ID `n+1`). Striding by `0x8000` reads only every
  8th geography.
- Presence bytes are pair-swapped (`bitwXor(housing, 1)`); the value stream is
  **not** swapped. Tenure `t` uses bit `7 - t`.
- Member id columns in `cells` are **1-based** (match StatCan Member IDs); the
  CSV ground-truth `Coordinate` is also 1-based.
- **Family 2**: directory entries are in **geography member-id order**;
  geos-per-page is **computed** (`geo_count / n_pages`), never assumed. The page
  marker's **low nibble is the value-width code** (`0x8`→float64, `0x4`→int32,
  `0x2`→int16); the high nibble (`0x8` vs `0xa`) only changes the pad/`0xFF`
  trailer length — `0xa` is **not** a suppression flag, `0xa*` pages carry real
  inline data.
- **Presence is a power-of-two-nested positional bitmap** over the data
  dimensions (descriptor order, outermost first; each level padded to the next
  power of two of count × inner-block; innermost in the low bits). Records are
  **byte-pair-swapped** then read **MSB-first**.
- **Value run start** = `4 + presence_len + trailer(b2) + 32·(b3 − 8)`
  (`presence_len = rec_bytes × geos_per_page`); trailer and head come from the
  marker (`ivt_value_trailer(b0, b2, b3)`): trailer = `b2 == 0x00` → 0, else
  `2·(b2 >> 4) + 2·(low nibble(b2) > 0)`; head = `32·(b3 − 8)`, `b3 ∈ {08,09,0a,0c}`.
  Unknown markers **abort** (`canivt_unknown_marker`). Every page is extent-checked
  against its directory entry's u16 size (`4 + presence + trailer + head + nv·width
  ≤ size`, **equality when `b2 == 0` and `b3 ≤ 09`** — `b3 ≥ 0a` pages append
  absent-cell mask tails; `canivt_page_overrun`). Valid entries pointing at unknown
  markers are skipped **loudly** (`canivt_skipped_pages`). The store keeps only
  **non-zero** cells, so a missing cell = 0; entirely empty geographies (zero
  presence record) are normal. A **ZERO high nibble in b0 is the DENSE page
  variant** (1991 profiles): bytes 3–4 are a u16 value COUNT, not b2/b3 —
  `[b0][01][u16 count]` + one value per grid position, zeros stored literally,
  count zero-padded past the window, exact fit `4 + count·width == size`
  (`ivt_decode_page_dense()`).
- **Fallbacks are LOUD** (`ivt_fallback()`, `fallback.R`): every content-heuristic
  path (stride walk, regex/dedup scans, count-keyed labels, marker-scan directory
  location, fixed slot orders, tail windows) raises a classed `canivt_fallback`
  warning when it supplies values; `options(canivt.strict = TRUE)` upgrades these
  (and skipped pages) to errors. Detection probes stay quiet (`ivt_quietly()`).
  When adding a new fallback path, wire it through `ivt_fallback()` — never let a
  heuristic read engage silently.
- The header dir pointer **`@558` stores only the LOW 16 BITS of the directory
  offset**: `ivt_idx0()` unwraps it (smallest `+ k·65536` whose entry validates).
  The page-directory entry floor is **1024** (past the header region), not 1e5.
- **`ivt_f2_decodable()` = descriptor + layout + `ivt_page_preflight()`** — the
  whole detection gate (`ivt_family()` returns the layout's `geo_in_page`). The
  pre-flight checks the first pages: extent within the entry size, **exact fit for
  `b2 == 0` pages**, presence count ≤ the page's **real cell capacity**
  (`min(ipc1, straddle count) · prod(inner)`), and the directory must **span the
  outer entry cartesian**. A pre-flight rejection can mean **the descriptor was
  misread**, not that the container is alien (it has repeatedly flagged a misread
  count, not an alien file — see history).
- `cells` data columns are named by a **purely generic, name-agnostic slug**
  (`ivt_dim_slug()`): the geography dimension (`ivt_f2_geo_dim_index()`) → `geo`,
  every other dimension takes the lower-cased leading word of its metadata name,
  made unique. Columns stay in descriptor order, so `geo` need not be first
  (1981004: `values, profile, geo`). **No code branches on dimension names or type
  bytes** — everything the decoder needs is structural (positions, counts, the
  2048-bit cap). Labels come from the codebook at `tidy` time. `ivt_tidy()`/parquet
  default to **slug** names (`dim_names = "slug"`; `"label"` gives the full label,
  or `label_ivt_columns()` relabels a parquet connection on read) — an output-layer
  rename in `ivt_data_colnames()`; `x$cells` stays on slugs.
- Use `ivt_f2_geo_count()` (descriptor geography record), **not**
  `ivt_f2_header_geo_count()` (the fixed-offset u16 reads a wrong 16320 for 4-dim
  descriptors), for any geography sizing.
- **Geography is the first descriptor dimension EXCEPT the profile lineage**
  (`ivt_f2_geo_dim_index()`, dimdir.R — 97-570-X1981004 / 98F0172X / 95F0170X store
  a 1-member "Values" placeholder first and geography LAST): dim 1 is the fast-path
  default, and only when dim 1 has a single member are the slot directories probed
  for a geography signature (GEO_NAME schema field / inline combined-block members).
  Identification is **never by a type byte**: the geography descriptor *type* is a
  **storage-width tag** for the member count — `ivt_f2_descriptor()` reads **u16**
  for `0x10`/`0x0d`/`0x0a`/`0x0c`/`0x09`, **u8** otherwise. (`0x09` is a u16 width
  tag for a *data* dimension: the >256-member detailed-classification dims, e.g.
  97F0020X Selected(282), 98-10-0174 Mother tongue(331).) `ivt_f2_data_dims()`
  takes "all dims except the geography index".
- **Double-01 descriptor records are ambiguous — counts are reconciled against the
  codebook** (`ivt_f2_dim_count_reconcile()`, dimdir.R): the reference-period record
  `[type][count][01][01]` ("Year (2)": `0e 02 01 01`) shares its byte shape with the
  profile "Values" placeholder (`00 20 01 01`, whose real count is 1, not 32). For
  such records the dimension's slot-directory member block decides (a descriptor
  count exceeding the block's slot count — slots only pad upward — is replaced by
  the block's real member count).
- **`ivt_f2_descriptor()` anchors dimension records on the doubled name**, not a
  fixed `<type> 01 <upper>` marker. Each record stores its name twice after a `0x01`;
  the **first copy may be truncated** (~14 chars; longest matching prefix wins) and
  the name may start with an uppercase letter **or a digit**. The type byte is a
  storage/classification tag, **not** a fixed dimension identity. The header
  **`n_dim` field is unreliable** — gate on `length(d$dims)`, never `d$n_dim`.
  Handles the **INVERTED layout** (records *before* the `81 01 20 00 … 80 03`
  signature; retried from the last `81 02 03 00` before D when the forward walk
  finds < 2 records) and **PROSE-BLEED names** (2001 F-series 97F0015X: description
  text bleeds into/between the two copies; two count-anchored fallbacks in
  `ivt_f2_descriptor_name()` recover them — data-dim names end in `(count)`, the
  geography name is the longest prefix that reoccurs later in the run).
- **There is ONE decode pattern — "family 1 / family 2" are two cases of it**
  (`decode.R`, `ivt_layout()` + `ivt_decode()`). Nest **every** dimension
  power-of-two-positionally (`ivt_f2_bit_layout()`), data dims innermost (descriptor
  order, last fastest) and geography outermost. Each page carries a fixed **2048-bit
  (256-byte) presence record**, filled innermost-first; the same nesting describes
  the in-page bits **and** the 8-byte directory entries. **Exactly one dimension
  straddles** the 2048-bit boundary: its in-page part (`ipc = floor(2048/inner_block)`)
  stays in the bitmap, the rest becomes `window_count = ceil(count/ipc)` directory-
  paged windows; every dimension *outside* the straddle is positional in the directory
  (power-of-two-nested entry strides, window innermost). The "family" is just **which
  dimension straddles**:
  - a **data** dimension straddles → geography is pushed fully into the directory,
    one page per (geography, outer-data-coord) (former "family 1": 0241 Period, geo
    stride 512 entries=0x1000; 0077 Ages; 0662 Health, geo stride 16=0x80).
  - the data dims fit ≤2048 bits → **geography straddles**: `gpp = 2048 / data_bits`
    geographies share each page's presence record, directory is a flat list of
    geography-window pages (former "family 2": 0023 4/page, 0129 2/page, 1991 4/page).
  `ivt_layout()$geo_in_page` is the discriminator (`straddle == geo_dim`). The nesting
  is purely POSITIONAL and never asks which dimension is geography — on the 1981
  profile (geography = dim 3, LAST) the same walk puts geography in the presence
  record (3 windows), Profile at directory stride 4, Values as the trivial outermost
  entry dimension.
- A **reference-period / facet** dimension (type `0x0e`, e.g. "Year (2)") is **not**
  geography-folded: in 98-10-0077 *Year* is the **innermost in-page dimension** (the
  value run carries the 2020 then 2015 value consecutively). `ivt_f2_geo_count()`
  (descriptor) gives the true 174 geographies; the legacy `ivt_geography_count()`
  (0x1000 stride) is used only by the family detector.

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

**The corpus regression ledger** (`tests/testthat/test-corpus.R` +
`fixtures/corpus-ledger.csv`) runs the WHOLE local corpus (one folder per table
under `CANIVT_IVT_CACHE`) through `read_ivt()` and asserts, per table: the
`ivt_is_supported()` verdict, strict-mode cleanliness (`strict_clean = FALSE`
rows are the KNOWN fallbacks — they must warn `canivt_fallback`, not error, so
both a vanished warning and a new failure trip the test) and the exact non-zero
cell count (the cheapest whole-pipeline invariant — a collapsed dimension
changes it). It decodes ~150M cells in ~4 min, so it is **opt-in**:

```sh
CANIVT_CORPUS_TESTS=1 Rscript -e 'devtools::test(filter = "corpus")'
```

When a gap is closed or a table is onboarded, update the ledger row (and
`inst/notes/coverage.md`) in the same commit.

`.ivt` and large `.csv` files are git-ignored; never commit them.

## Open tasks

The decoder, unified metadata, uniform geography parsing and the family-2
attribute table are all **done** — the corpus is fully supported. That work log
(and how each table was cracked) lives in
[`decode-history.md`](inst/notes/decode-history.md). What remains is small:

- **Synthetic aggregate geographies decode a `geo_label` but no `geo_name`/
  `geo_uid`/`geo_level`** (e.g. 98-10-0662's member 26, "Canada outside Quebec
  and New Brunswick"): the schema attribute block stores nothing for them, so
  those columns are `NA`. Faithful to the file but a semantic gap — derive
  `geo_name` from `geo_label` (and synthesise a uid/level) for such members. See
  the `[ ]` item in [`coverage.md`](inst/notes/coverage.md). (An `NA` label used
  to crash `ivt_label_parent`; that is fixed — `NA` → depth 0, no parent.)
- **`DQF_NOTE` texts > 252 chars are stored truncated in the file** (the 1-byte
  record length caps at `0xFC`) — 2,448 members on 0129, 90 on 0478. Not a decode
  gap; byte-faithful to the container.
- **0478's last-group GEO_NAME code partial (153 members) stays `NA`** — the block
  scanner fragments that code chunk; `geo_label` and every other attribute are
  complete.
- **Per-*member* footnote attribution** (nicety): footnotes are dimension-attributed;
  the small records preceding each footnote pair in the slot directory look like
  member references but are unverified.
- **Optional niceties:** expose the per-dimension `depth` directly on `ivt_tidy()`
  output; consider an `Rcpp` fast path only if pure-R decode becomes a bottleneck
  (it is fine at ~5 s for the reference table).

## Provenance

The reverse-engineering work started as part of a different project specifically
aimed at on-boarding older census data into CensusMapper and the initial import
scripts formed the seed of the **canivt** package with the aim to generalize this.

