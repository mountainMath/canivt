# CLAUDE.md — canivt

**canivt** downloads and parses StatCan *Beyond 20/20* `.ivt` tables into tidy
data / Parquet / CSV, plus their metadata (dimension members, geographic
identifiers/DGUIDs, footnotes).

**Parsing must be driven by metadata and markers found in the file itself.**
External ground truth (2021 CSVs, the web viewer) is for *validation only* —
never a hidden hard-coded parsing path. Parsers must generalize to files the
test suite has not seen, and warn loudly on every fallback.

## Companion docs (`inst/notes/`)

| doc | role |
|-----|------|
| [`ivt-format.md`](inst/notes/ivt-format.md) | authoritative byte-format reference. **Read before changing the parser.** (User-facing copy: `vignettes/ivt-format.Rmd`.) |
| [`markers.md`](inst/notes/markers.md) | terse byte-marker catalog. Self-checked by `test-markers.R` (catalog↔code equality + opt-in corpus sweep that fails on an un-catalogued marker). **Update in the same commit as the recognizer.** |
| [`coverage.md`](inst/notes/coverage.md) | living completeness tracker + measured byte coverage. **Update when a gap opens or closes.** |
| [`decode-history.md`](inst/notes/decode-history.md) | narrative changelog: how each table was cracked, per-table validation records, invariant derivations. Consult for the *why*. |
| [`unsupported-formats.md`](inst/notes/unsupported-formats.md) | the UNSUPPORTED ledger: what the gate refuses and why. |
| [`refactor-plan.md`](inst/notes/refactor-plan.md) | consolidation backlog (open items only). |
| [`onboarding-backlog.md`](inst/notes/onboarding-backlog.md) | the repeatable per-table onboarding recipe. |

## What works today

**Almost every `.ivt` in the corpus decodes.** One descriptor-driven,
name/type-agnostic decoder (`decode.R`: `ivt_layout()` + `ivt_decode()`) plus one
shared metadata path (`ivt_f2_metadata()`) handle every vintage. The historical
"family 1 / family 2" split is **not two formats** — it is one power-of-two-nested
positional layout differing only in *which* dimension straddles the 2048-bit page
boundary. Whole-file pure-R decode of the 7.5M-cell reference table: ~4–5 s.

Validated cell-exact on six reference tables (0241/0077/0662 data-dim straddle;
0023/0129/1991 geography straddle) and viewer/CSV-validated across the corpus:
1996–2021 census, 1981/1991 profiles, 2001/2006 F-series, 2016 `98-400-X`
crosstabs, custom cro/ord extracts, Canadian Business Patterns, and the
`02 00 20 00` survey generation (byte 0 == `0x02`; these have **no geography
dimension** — `ivt_f2_geo_dim_index()` returns 0, no `geo` column).

The only ledgered exceptions are deliberately-UNSUPPORTED guard files (see
`unsupported-formats.md`), kept in the corpus ledger as `supported = FALSE` so the
gate can never silently emit unvalidated values.

Key semantics:

- **The store keeps only non-zero cells** (the CSV publishes zeros) — an absent
  cell is a zero *within a geography that carries data*. **Suppression is
  whole-geography**: no stored cells ⇒ wholly suppressed/empty, exposed as
  `metadata$geographies$has_data`. There is no per-cell sentinel.
- **Geography metadata is on the DEFAULT path**: `metadata$geographies` packs every
  decoded per-member column (bilingual `geo_label`/`geo_name`, `geo_uid`,
  level/type, geocodes, `dqf_code`, `tnr_short_form`; all-NA columns dropped).
  `read_ivt(geo_attributes = TRUE)` adds the full attribute table for large chunked
  tables (~30 s block scan).
- `read_ivt()` auto-detects via `ivt_family()`, but decode and metadata are shared;
  `family` only tags provenance and gates `geo_attributes`.

## Code map (`R/`)

| file | role |
|------|------|
| `utils-bytes.R` | low-level readers `rd_u16/rd_u32/rd_int_run/rd_pascal`, latin-1 decode. **All offsets 0-based**; helpers convert to R's 1-based indexing. |
| `fallback.R` | **loud fallbacks**: `ivt_fallback(msg, class)` raises a classed `canivt_fallback` warning whenever a heuristic supplies values or pages are skipped; `options(canivt.strict = TRUE)` upgrades to an error. `ivt_quietly()` muffles both for detection probes. Wire every new fallback through this. |
| `container.R` | page-directory anchor `ivt_idx0()` (`u16@558`, validated against the first page marker; `IVT_IDX0_DEFAULT` is the fallback). |
| `decode.R` | **the unified cell decoder.** `ivt_layout()` nests every dimension (data innermost, geography outermost), finds the one straddle dim at the 2048-bit cap, computes in-page/straddle/paged roles, the bit grid and the 8-byte directory strides — every level padded to the declared slot allocation (`ivt_f2_dim_slot_alloc()`). `ivt_decode()` walks the paged cartesian and decodes each page (`ivt_f2_record_present()` + `ivt_value_trailer()`; dense pages via `ivt_decode_page_dense()`) → cell tibble (`geo` + one slug column per data dim). |
| `container-f2.R` | family-2 page-directory finder + the marker byte model (`ivt_f2_is_marker()`: `b0` width/variant nibbles, `b3 ∈ {08,09,0a,0c}` head codes); `ivt_f2_geos_per_page()` / `ivt_f2_geography_count()`. |
| `decode-f2.R` | shared presence-bitmap primitives (the `ivt_f2_` prefix is historical — used by every family): `ivt_f2_nextpow2()`, `ivt_f2_bit_layout()`, `ivt_f2_cell_grid()`, `ivt_f2_record_present()` (byte-pair-swap, MSB-first). |
| `dimdir.R` | **bilingual labels, dimension names, header directory slot table.** `ivt_f2_dim_dir_label1()` → `list(en, fr, name_fr)`, EN/FR chosen structurally (`ivt_f2_dim_dict_en_first()`; `ivt_f2_frscore()` is the loud fallback). **Header `@824 + 14·(k−1)`** holds a 14-byte record per descriptor dimension (`[u32 dir_ptr][u32 ?][u32 n_entries][2B]`) — the primary codebook anchor: `ivt_f2_dim_slots()` reads it, `ivt_f2_dim_dir(raw, k)` resolves dimension `k`'s block directory (`[u32 off][u16 len][u16 len]`, two indirection depths for big chunked geo dirs), self-validated against `n_entries`. Each directory lists that dimension's codebook in logical order (dictionary/schema, member-id table, ordinals, the `81 02 02 00` doubled-name marker, EN then FR member blocks, footnotes). Readers: `ivt_f2_dim_dir_labels()`, `ivt_f2_dim_dir_ordinals()`, `ivt_f2_dir_footnotes()` (with `scope`/`dimension`/`member_id`; member notes flagged by an `84 01` bitmap, `ivt_f2_footnote_bitmap()`), `ivt_f2_table_footnotes()`. Other header slots: `ivt_f2_master_dir()` (`@544` → master directory at 992) and `ivt_f2_dqf_legend()` (`@712`, `[82 01]`-framed EN/FR per code A–E/R/P). |
| `codebook-f2.R` | **the unified codebook.** `ivt_f2_geo_read(raw, full)` is the single geography dispatcher; `ivt_f2_geo_light()` (metadata default) and `ivt_f2_geographies()` (`geo_attributes = TRUE`) are thin wrappers. Stage 1 `ivt_f2_geo_entries()` locates the geo block directory once and exposes lazy memoized `records`/`strict`/`values` accessors shared by all six readers. Then an ordered specializer chain: flow → inline → schema → custom → bare; a complete uid array wins for big chunked DGUID tables; else Stage 3 `ivt_f2_geo_combined()` is the last-resort net (`canivt_geo_unparsed`, loud). Column identity is **metadata-driven** where declared — the `81 02` field dictionary (`ivt_f2_geo_field_schema()` + `ivt_f2_geo_field_roles()`) maps runs to `geo_name`/`geo_name_fr`/`geo_uid` by the file's own field names; only without a matching dictionary does it fall to content heuristics. Readers: `ivt_f2_geo_simple()` (cheap names+DGUIDs, schema-addressed), `ivt_f2_geo_attributes()` / `ivt_f2_geo_attrs_dir()` (the **primary** attribute reader — every attribute read positionally, per group `[display + schema fields]` × EN-then-FR runs, ordinals dropped, per-member footnote text blobs skipped via `ivt_f2_dir_is_text_block()`; stride path `ivt_f2_geo_root_dir()` retained but unreached), `ivt_f2_geo_inline()` (schema-absent 1991/2006/2011/2016 combined blocks `"name (code) [type] flag [(pct%)]"`), `ivt_f2_geo_flow_dir()` / `ivt_f2_flow_sides()` (**origin-destination commuting flows**, geo type `0x0f`: a flow decodes as **two** geographies — the file's POR/POW schema → `geo_res_*`/`geo_work_*`, pair kept as `geo_uid`; anchored on the uid array, labels joined back by code), `ivt_f2_dim_member_labels()` (data-dim labels via the doubled-name marker). Two loud name fills guarantee a `geo_name` for every member: `ivt_f2_inline_name_subtract()` and `ivt_f2_geo_fill_label()` (both fill NAs only). Snapshot-guarded by `fixtures/geo-snapshot.csv`. **Slugs** (`ivt_dim_slug()`) are generic: lower-cased leading word of the dimension name, made unique. |
| `read-f2.R` | **unified metadata + tidy**: `ivt_f2_metadata()`; `ivt_f2_vl_pairs()` + `ivt_f2_dim_name()` (header Variable List names, matched to the descriptor by count); `ivt_f2_dimensions()` (per-dim `name/count/type/is_geography/members`); `ivt_f2_footnotes()` (table + dimension + member notes, renumbered by `ivt_f2_footnote_finalize()`, each with `scope`/`dimension`/`member_id`/`member_refs`) + `ivt_f2_legacy_footnotes()` / `ivt_f2_note_refs()` (the legacy `(N)` markers in labels); `ivt_f2_tidy()`; `ivt_data_colnames()`. |
| `codebook.R` | shared codebook primitives: `ivt_find_member_blocks()` Pascal-run scanner, `ivt_header_text()` / `ivt_table_info()`, `ivt_footnote_texts()`. |
| `suba.R` | the **type-00 sub-A** provincial Business-Patterns module (`ivt_f2_suba_annotate()`): measures the non-declared directory stride from the page directory, recovers the under-declared industry count from codebook chunks, and **commits only if the decode reconciles** (industry-Total == Σ detail, or Canada == Σ provinces) — else the file stays honestly UNSUPPORTED. Industry **labels are PROVISIONAL** (`canivt_suba_labels`, loud): reconciliation validates sums, not the code→member assignment. |
| `read.R` | public `read_ivt()`, `ivt_metadata()`, `ivt_tidy()`, `print.ivt` — one path for all families; `ivt_family()` detector + `ivt_is_supported()` gate. `ivt_tidy(dim_names=)` names columns by slug (default) or full label; `x$cells` always keeps slugs (the naming is an output-layer rename shared with `ivt_members()`). `ivt_tidy(language=)` gives EN (default) or FR labels, falling back per column. **Parquet paths carry a language marker** (`<key>_en/_fr.parquet`); `ivt_members_path()` strips it so one `_members.parquet` sidecar serves both. `ivt_parquet_language()`, `label_ivt_columns()`. Geography columns keep `geo_*` names; `geo_uid` is language-neutral. |
| `collect.R` | **factor-level context**: `ivt_members(x)` (one row per tidy column × member with `member_id`/`ordinal`/`label`/`level`/`depth`); `collect_ivt(x, members, geography)` converts dimension columns to factors whose levels are the **full** member list in ordinal order (filtered-out members stay as levels; geography opt-in). Levels travel as a `<name>_members.parquet` sidecar. Ordinals from `ivt_f2_dim_dir_ordinals()` (must be a permutation of `1..count`). |
| `catalogue.R` | scrapes the StatCan census datasets index into a product catalogue (`statcan_ivt_years()`, `statcan_ivt_catalogue()`, `statcan_ivt_resolve_url()`), cached as Parquet. Needs `rvest` + `xml2`. |
| `borealis.R` | Borealis Dataverse source: `borealis_ivt_catalogue()` (needs `BOREALIS_DATAVERSE_KEY`, ~90 s, cached — reading the cache needs neither), `borealis_ivt_download()`. |
| `get.R` | `get_statcan_ivt(source, …)` — one-stop accessor. `source` = StatCan catalogue number, Borealis id/key/`file_id`, local custom id, a one-row catalogue tibble, or a named length-one `c(key = "url-or-path")`. Resolves → downloads → decodes → caches tidy Parquet → returns an `arrow::open_dataset()` connection. `keep_ivt = FALSE` (default) discards the raw `.ivt`. Also `list_ivt_cache()` and `prune_ivt_cache()`. |
| `ground-truth.R` | **internal** — scrapes the public B20/20 HTML viewer (`Rp-eng.cfm`) to build validation fixtures. `ivt_gt_viewer_url()`, `ivt_gt_slice()`, `ivt_ground_truth()`. Returns one row per cell with a `value` + per dimension a slug label and a 1-based `<slug>_id` **position** (the label-independent join key). |
| `cache.R` / `zzz.R` | `ivt_cache_dir("ivt"\|"data")` (options `canivt.ivt_cache` / `canivt.data_cache`, else `tempdir()`); `.onLoad` seeds them from `CANIVT_IVT_CACHE` / `CANIVT_DATA_CACHE`. |
| `download.R` | `ivt_download()`, `ivt_store_download()` (sniffs zip vs raw), `ivt_pid8()`. |
| `write.R` | `ivt_write_parquet()/_csv()/_metadata()` (parquet also writes the `_members` sidecar); `ivt_label_depth()` / `ivt_label_parent()` (indentation → hierarchy). |
| `canivt-package.R` | `ivt_read_table()` one-shot wrapper + package doc. |

## Key invariants (don't regress)

The *rules*; the measurements and original bugs behind them are in
[`decode-history.md`](inst/notes/decode-history.md) ("Invariant derivations").

- **There is ONE decode pattern** (`decode.R`) — nest every dimension
  power-of-two-positionally, data dims innermost (descriptor order, last fastest),
  geography outermost. Each page carries a fixed **2048-bit (256-byte) presence
  record**; the same nesting describes the in-page bits **and** the 8-byte directory
  entries. **Exactly one dimension straddles** the 2048-bit boundary: its in-page
  part (`ipc = floor(2048/inner_block)`) stays in the bitmap, the rest becomes
  `window_count = ceil(count/ipc)` directory-paged windows; everything outside the
  straddle is positional in the directory. The "family" is just *which* dimension
  straddles — a data dim (former family 1) or geography (former family 2);
  `ivt_layout()$geo_in_page` is the discriminator. The walk never asks which
  dimension is geography (on the 1981 profile, geography is dim 3 and lands in the
  presence record).
- **All nesting geometry — presence-bit AND directory strides — pads each dimension
  to its DECLARED slot allocation** (`ivt_f2_dim_slot_alloc()`: the u16 opening the
  dimension's `81 02 <alloc-u16> 16 00` member-code block or `08 00` time table),
  falling back to `nextpow2(extent)` only when the declaration cannot hold the
  members (chunked >1024-member dims declare a block-local 1024).
- **The bitmap addresses members by SLOT, and slots can have holes.** The survey
  generations' time dimensions store a `81 02 <alloc-u16> 08 00` **time-series
  member table** (`ivt_f2_time_members()`, markers.md §E.1): a u16 slot capacity +
  `alloc` one-byte slot flags (**pair-swapped**; non-zero = populated) + one u24 LE
  date per member, right-aligned, **days since 0000-03-01** (labels are generated
  from the dates). When slots ≠ `1..count` the dim carries `$slots`, extents drive
  the geometry, `ivt_f2_cell_grid(pos=)` maps bits to slots, and a value at a
  deleted slot warns `canivt_slot_hole`.
- Presence bytes are **pair-swapped** (`bitwXor(i, 1)`) and read **MSB-first**; the
  value stream is **not** swapped.
- **Value run start** = `4 + presence_len + trailer(b2) + 32·(b3 − 8)`
  (`presence_len = rec_bytes × geos_per_page`), from the marker
  (`ivt_value_trailer(b0, b2, b3)`): trailer = `b2 == 0x00` → 0, else
  `2·(b2 >> 4) + 2·(low nibble(b2) > 0)`; head = `32·(b3 − 8)`, `b3 ∈ {08,09,0a,0c}`.
  Unknown markers **abort** (`canivt_unknown_marker`); valid entries pointing at them
  are skipped loudly (`canivt_skipped_pages`). Every page is extent-checked against
  its directory entry's u16 size, with **equality only when `b2 == 0` and `b3 == 08`**
  (pages with a head block may append an absent-cell mask / allocation slack, so only
  `≤` applies; `canivt_page_overrun`). Decoding stays presence-authoritative (exactly
  `popcount` values from the run start), so a tail never affects it.
- The page marker's **low nibble is the value-width code** (`0x8`→float64,
  `0x4`→int32, `0x2`→int16); the high nibble (`0x8` vs `0xa`) only changes the
  pad/`0xFF` trailer length — `0xa` is **not** a suppression flag. A **zero high
  nibble in b0 is the DENSE page variant** (1991 profiles): bytes 3–4 are a u16
  value COUNT, one value per grid position, zeros stored literally, exact fit
  `4 + count·width == size` (`ivt_decode_page_dense()`).
- Directory entries are in **geography member-id order**; geos-per-page is
  **computed** (`geo_count / n_pages`), never assumed. Legacy index stride `0x1000`
  → 166 geographies on the reference table (directory `n` → Member ID `n+1`).
- Member id columns in `cells` are **1-based** (match StatCan Member IDs); the CSV
  ground-truth `Coordinate` is also 1-based.
- The header dir pointer **`@558` stores only the LOW 16 BITS** of the directory
  offset — `ivt_idx0()` unwraps it (smallest `+ k·65536` whose entry validates).
  The page-directory entry floor is **1024**.
- **`ivt_f2_decodable()` = descriptor + layout + `ivt_page_preflight()`** — the whole
  detection gate. The pre-flight checks extent within the entry size, exact fit for
  `b2 == 0` pages, presence count ≤ the page's real cell capacity, and that the
  directory **spans the outer entry cartesian**. A rejection often means **the
  descriptor was misread**, not that the container is alien.
- **`ivt_f2_descriptor()` anchors dimension records on the doubled name**, not a
  fixed `<type> 01 <upper>` marker: each record stores its name twice after a `0x01`,
  the **first copy may be truncated** (~14 chars; longest matching prefix wins), and
  the name may start with an uppercase letter **or a digit**. The type byte is a
  storage/classification tag, **not** dimension identity. The header **`n_dim` field
  is unreliable** — gate on `length(d$dims)`. Handles the **INVERTED layout**
  (records before the `81 01 20 00 … 80 03` signature) and **PROSE-BLEED names**
  (2001 F-series: two count-anchored fallbacks in `ivt_f2_descriptor_name()`).
- **Double-01 descriptor records are ambiguous — counts are reconciled against the
  codebook** (`ivt_f2_dim_count_reconcile()`): `[type][count][01][01]` is shared by
  the reference-period record ("Year (2)": `0e 02 01 01`) and the profile "Values"
  placeholder (`00 20 01 01`, real count 1). The dimension's slot-directory member
  block decides; the same reconcile adopts a chunk-run count wherever it exceeds the
  descriptor's (chunked >256-member dims).
- **Geography is the first descriptor dimension EXCEPT the profile lineage**
  (`ivt_f2_geo_dim_index()` — 97-570-X1981004 / 98F0172X / 95F0170X put a 1-member
  "Values" placeholder first and geography LAST). Dim 1 is the fast path; only when
  dim 1 has a single member are the slot directories probed for a geography
  signature. Identification is **never by type byte**: the geography descriptor
  *type* is a **storage-width tag** for the member count — `ivt_f2_descriptor()`
  reads **u16** for `0x10`/`0x0d`/`0x0a`/`0x0c`/`0x09`/`0x0f`, **u8** otherwise
  (`0x09` = a >256-member *data* dim; `0x0f` = the 2011 NHS commuting-flow
  geography). `ivt_f2_data_dims()` = all dims except the geography index.
  Use `ivt_f2_geo_count()` (descriptor record), **not**
  `ivt_f2_header_geo_count()`, for any geography sizing.
- A **reference-period / facet** dimension (type `0x0e`) is **not** geography-folded:
  in 98-10-0077 *Year* is the innermost in-page dimension.
- `cells` data columns are named by a purely generic, **name-agnostic slug**
  (`ivt_dim_slug()`); columns stay in descriptor order, so `geo` need not be first.
  **No code branches on dimension names or type bytes** — everything the decoder
  needs is structural (positions, counts, the 2048-bit cap). Labels come from the
  codebook at `tidy` time.
- **Fallbacks are LOUD** (`ivt_fallback()`): every content-heuristic path (stride
  walks, regex/dedup scans, count-keyed labels, marker-scan directory location,
  fixed slot orders, tail windows) raises a classed `canivt_fallback` warning when it
  supplies values; `canivt.strict` upgrades these (and skipped pages) to errors.
  Detection probes stay quiet (`ivt_quietly()`). Wire every new fallback through it.

## Dev workflow

```r
devtools::load_all(".")
devtools::document()   # after changing roxygen comments
devtools::test()       # unit tests always run; decode tests need a sample
devtools::check()
```

Integration tests need real `.ivt` files and auto-skip without them:

| env var | file (fallback path) |
|---------|----------------------|
| `CANIVT_SAMPLE_IVT` | `98100241.ivt` (`~/projects/censusmapper-import/data/raw/98100241/`) |
| `CANIVT_SAMPLE_IVT_F2` | `98100023.ivt` (`/tmp/t23/`) |
| `CANIVT_SAMPLE_IVT_F2_4D` | `98100129.ivt` (`/tmp/t129/`) |
| `CANIVT_SAMPLE_IVT_1991` | `1003011.IVT` |

**The corpus regression ledger** (`tests/testthat/test-corpus.R` +
`fixtures/corpus-ledger.csv`) runs the whole local corpus (one folder per table
under `CANIVT_IVT_CACHE`) through `read_ivt()` and asserts, per table: the
`ivt_is_supported()` verdict, strict-mode cleanliness (`strict_clean = FALSE` rows
are the KNOWN fallbacks — they must *warn*, not error, so both a vanished warning
and a new failure trip the test) and the exact non-zero cell count. ~150M cells in
~4 min, so it is **opt-in**:

```sh
CANIVT_CORPUS_TESTS=1 Rscript -e 'devtools::test(filter = "corpus")'
```

When a gap is closed or a table onboarded, update the ledger row **and**
`inst/notes/coverage.md` in the same commit.

`.ivt` and large `.csv` files are git-ignored; never commit them.

## Open tasks

The decoder, unified metadata, uniform geography parsing, the family-2 attribute
table, commuting-flow decoding, footnote scope and geo-name completeness are all
**done**; the onboarding backlog is cleared (2026-07-21).

- **The `81 02 <alloc> 16 00` block's mid-section (likely per-slot flags) is
  undecoded.** Decoding it would subsume the `ivt_f2_dim_slot_expand()` deleted-slot
  margin heuristic and fix the accs **Offences** label alignment (64 stored labels
  for 40 members; currently a count-anchored scan, possibly misaligned).
- **type-00 sub-A industry labels are PROVISIONAL** (`R/suba.R`) — reconciliation
  validates sums, not code→member assignment, and no ground truth exists. Three
  files in that cluster stay UNSUPPORTED.
- **`Rcpp` fast path** — only if pure-R decode becomes a bottleneck (~5 s for 7.5M
  cells is fine).

Two resolved behaviours are **accepted by design** (detail in `decode-history.md`):
source-side `DQF_NOTE` truncation (>252 chars, truncated by StatCan's writer —
surfaced via `dqf_note_truncated` + a `canivt_source_truncation` warning that stays
a warning under strict), and synthetic-aggregate geographies whose `geo_uid` /
`geo_level` are genuinely absent and correctly stay `NA`.

## Provenance

The reverse-engineering started in a project on-boarding older census data into
CensusMapper; those import scripts seeded **canivt**.
