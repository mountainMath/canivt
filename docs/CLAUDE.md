# CLAUDE.md — canivt

**canivt** downloads and parses StatCan *Beyond 20/20* `.ivt` tables
into tidy data / Parquet / CSV, plus their metadata (dimension members,
geographic identifiers/DGUIDs, footnotes).

**Parsing must be driven by metadata and markers found in the file
itself.** External ground truth (2021 CSVs, the web viewer) is for
*validation only* — never a hidden hard-coded parsing path. Parsers must
generalize to files the test suite has not seen, and warn loudly on
every fallback.

## Companion docs (`inst/notes/`)

| doc | role |
|----|----|
| [`ivt-format.md`](https://mountainmath.github.io/canivt/inst/notes/ivt-format.md) | authoritative byte-format reference. **Read before changing the parser.** (User-facing copy: `vignettes/ivt-format.Rmd`.) |
| [`markers.md`](https://mountainmath.github.io/canivt/inst/notes/markers.md) | terse byte-marker catalog. Self-checked by `test-markers.R` (catalog↔︎code equality + opt-in corpus sweep that fails on an un-catalogued marker). **Update in the same commit as the recognizer.** |
| [`coverage.md`](https://mountainmath.github.io/canivt/inst/notes/coverage.md) | living completeness tracker + measured byte coverage. **Update when a gap opens or closes.** |
| [`decode-history.md`](https://mountainmath.github.io/canivt/inst/notes/decode-history.md) | narrative changelog: how each table was cracked, per-table validation records, invariant derivations. Consult for the *why*. |
| [`unsupported-formats.md`](https://mountainmath.github.io/canivt/inst/notes/unsupported-formats.md) | the UNSUPPORTED ledger: what the gate refuses and why. |
| [`refactor-plan.md`](https://mountainmath.github.io/canivt/inst/notes/refactor-plan.md) | consolidation backlog (open items only). |
| [`onboarding-backlog.md`](https://mountainmath.github.io/canivt/inst/notes/onboarding-backlog.md) | the repeatable per-table onboarding recipe. |

## What works today

**Every `.ivt` in the corpus decodes.** One descriptor-driven,
name/type-agnostic decoder (`decode.R`: `ivt_layout()` + `ivt_decode()`)
plus one shared metadata path (`ivt_f2_metadata()`) handle every
vintage. The historical “family 1 / family 2” split is **not two
formats** — it is one power-of-two-nested positional layout differing
only in *which* dimension straddles the 2048-bit page boundary.
Whole-file pure-R decode of the 7.5M-cell reference table: ~3 s (~6.5 s
completed to its 39.2M published rows).

Validated cell-exact on six reference tables (0241/0077/0662 data-dim
straddle; 0023/0129/1991 geography straddle) and viewer/CSV-validated
across the corpus: 1996–2021 census, 1981/1991 profiles, 2001/2006
F-series, 2016 `98-400-X` crosstabs, custom cro/ord extracts, Canadian
Business Patterns, and the `02 00 20 00` survey generation (byte 0 ==
`0x02`; these have **no geography dimension** — `ivt_f2_geo_dim_index()`
returns 0, no `geo` column).

**The refusal ledger is empty** (2026-07-26): all 170 corpus rows are
`supported = TRUE`, with no gate relaxed to get there.
`unsupported-formats.md` now records how rejection works and what each
former refusal turned out to be — keep it current, and if a file is ever
ledgered `supported = FALSE` again it goes there, so the gate can never
silently emit unvalidated values.

Key semantics:

- **[`read_ivt()`](https://mountainmath.github.io/canivt/reference/read_ivt.md)
  returns the PUBLISHED TABLE, not the store** (2026-07-28,
  `complete = TRUE` by default): one row per real grid coordinate,
  published zeros written out, flagged cells carrying `value = NA` +
  `symbol`/`status` factors. The rule is derived from the file’s own
  bytes — *absent ⇒ published zero unless the page’s cell-status block
  says otherwise* — never from a published CSV. Validated cell-for-cell
  against StatCan’s CSVs on 98-10-0040 / 0019 / 0021 / 0478 / 0655
  (every row present, no extra row, `max|d| = 0`, every symbol matched)
  and corroborated by WDS `nbDatapointsCube` = stored + flagged. A page
  whose tail cannot be read publishes its absences as zeros **and counts
  them** (`canivt_absent_unclassified`). `complete = FALSE` restores the
  store-only output; completion is refused above
  `getOption("canivt.max_cells", 1e8)` grid cells (the corpus grid
  totals 4.3B rows against 366M stored cells).
- **The store keeps only non-zero cells** (the CSV publishes zeros) — so
  an absent cell is *either* a zero or a missing value, and the page’s
  **cell-status block** is the only thing separating them. **“Absent ⇒
  zero” is FALSE in every vintage**; it merely looks true on tables that
  publish no missings. Whole-geography suppression (no stored cells at
  all ⇒ `metadata$geographies$has_data`) is still correct, just coarse.
- **The cell-status tail IS decoded** (2026-07-27), opt-in:
  `read_ivt(missing = TRUE)` → `x$missing`, a coordinate tibble shaped
  like `cells` minus `value` plus a `status` column, with a
  per-page-class tally in `attr(., "pages")`. **Both forms**, from one
  storage rule:
  - `0x8` → the 1-bit absent mask: masked absent ⇒ genuine zero,
    **UNMASKED absent ⇒ missing** (`N` in the viewer), `status = NA` (no
    reason stated). Proven on `97F0020XCB2001070` against the Beyond
    20/20 viewer (344 missings over the 86 tail-bearing pages of geos
    1–13, 0 for Nunavut — reproduced exactly) and confirmed from the
    other side by the CMHC crosstabs (0 unflagged; their B20/20 CSVs
    publish no missings). Also validated from the tables’ own arithmetic
    by `dev/mvalidate.R` — a coordinate whose absent cells are all
    masked reproduces its dimension’s Total to within random rounding,
    one with cells reported missing falls short by an amount that grows
    with how many.
  - `0xa` → the self-describing reason-code array: header
    `[form][02][W]` (+ `[u16]` when form 02) then a **`[01][W]`** array
    intro, codes `W` bits MSB-first (not pair-swapped) at the same
    `lay$grid$bit`. **`W` is a storage choice, not a dialect** — one
    file mixes widths — and code `0` is always a value or a genuine
    zero. **What the other codes MEAN is declared by the FILE**, not by
    the format: header slot **`@698`** points at the table’s own status
    legend — symbol plus bilingual wording, one record per code, in code
    order (`ivt_f2_status_legend()`, markers.md §H.1). **Seven distinct
    legends** over the 115 corpus tables that declare one, and they are
    *offset from each other* (NDM census `1 = ..`, `2 = X`, `3 = ...`;
    the profile / `98-400-X` / 2021-custom lineage starts one symbol
    earlier at `1 = -`), so a fixed table mislabels most of the corpus.
    Code `1` is the file’s own *nothing here*: filler at a padded grid
    position, the published symbol at a real cell — the GRID decides,
    and `coords_of()` already does. A code the legend does not name is
    counted, never translated (`canivt_status_code_unknown`, 0
    corpus-wide); a file declaring no legend falls back loudly to the
    NDM vocabulary (`canivt_status_legend`). `x$missing` carries
    `symbol` + `status`; the legend rides on
    `attr(x$missing, "legend")`. The array’s “lineage-specific
    addressing” was the block read **without the sparse rebuild**;
    rebuild first and one rule covers 1,273,173/1,273,173 corpus pages.
    Validated cell-exact in BOTH directions on **ten** tables
    (98-10-0002/0010/0013/0023/0040/0128/0129/0478/0655/0658) plus two
    internal checks: present ⇒ code 0 everywhere, and padding ⇒ code 1
    over 166,965,381 cells at every width.

  54 corpus tables report missings, 624,500,113 in all. See `R/status.R`
  below and `ivt-format.md`, “The cell-status block”.
- **Geography metadata is on the DEFAULT path**: `metadata$geographies`
  packs every decoded per-member column (bilingual
  `geo_label`/`geo_name`, `geo_uid`, level/type, geocodes, `dqf_code`,
  `tnr_short_form`; all-NA columns dropped).
  `read_ivt(geo_attributes = TRUE)` adds the full attribute table for
  large chunked tables (~30 s block scan).
- [`read_ivt()`](https://mountainmath.github.io/canivt/reference/read_ivt.md)
  auto-detects via `ivt_family()`, but decode and metadata are shared;
  `family` only tags provenance and gates `geo_attributes`.

## Code map (`R/`)

| file | role |
|----|----|
| `utils-bytes.R` | low-level readers `rd_u16/rd_u32/rd_int_run/rd_pascal`, latin-1 decode. **All offsets 0-based**; helpers convert to R’s 1-based indexing. |
| `fallback.R` | **loud fallbacks**: `ivt_fallback(msg, class)` raises a classed `canivt_fallback` warning whenever a heuristic supplies values or pages are skipped; `options(canivt.strict = TRUE)` upgrades to an error. `ivt_quietly()` muffles both for detection probes. Wire every new fallback through this. |
| `container.R` | page-directory anchor `ivt_idx0()` (`u16@558`, validated against the first page marker; `IVT_IDX0_DEFAULT` is the fallback). |
| `decode.R` | **the unified cell decoder.** `ivt_layout()` nests every dimension (data innermost, geography outermost), finds the one straddle dim at the 2048-bit cap, computes in-page/straddle/paged roles, the bit grid and the 8-byte directory strides — every level padded to the declared slot allocation (`ivt_f2_dim_slot_alloc()`). `ivt_decode()` walks the paged cartesian and decodes each page (`ivt_f2_record_present()` + `ivt_value_trailer()`; dense pages via `ivt_decode_page_dense()`) → cell tibble (`geo` + one slug column per data dim). `ivt_decode(missing = TRUE)` additionally reads each page’s status tail (`status.R`) **before** decoding it — so a wholly-suppressed page still contributes — and attaches the missing-cell tibble as `attr(cells, "missing")`; `coords_of()` is the shared coordinate build for both. Also `ivt_dir_outer_count()` — the **container count witness**: the directory’s own populated span for the outermost paged dimension. |
| `container-f2.R` | family-2 page-directory finder + the marker byte model (`ivt_f2_is_marker()`: `b0` width/variant nibbles, `b3 ∈ {08..0e}` head codes); `ivt_f2_geos_per_page()` / `ivt_f2_geography_count()`. |
| `decode-f2.R` | shared presence-bitmap primitives (the `ivt_f2_` prefix is historical — used by every family): `ivt_f2_nextpow2()`, `ivt_f2_bit_layout()`, `ivt_f2_cell_grid()`, `ivt_f2_record_present()` (byte-pair-swap, MSB-first). The grid carries its **bit addressing precomputed** (`ivt_bit_addr()`: plain byte index, pair-swapped byte index, MSB-first shift — the pair-swap is a permutation of the ADDRESS, not a copy of the record); hand `lay$grid` rather than `lay$grid$bit` to any bit reader to reuse it. |
| `dimdir.R` | **bilingual labels, dimension names, header directory slot table.** `ivt_f2_dim_dir_label1()` → `list(en, fr, name_fr)`, EN/FR chosen structurally (`ivt_f2_dim_dict_en_first()`; `ivt_f2_frscore()` is the loud fallback). **Header `@824 + 14·(k−1)`** holds a 14-byte record per descriptor dimension (`[u32 dir_ptr][u32 ?][u32 n_entries][2B]`) — the primary codebook anchor: `ivt_f2_dim_slots()` reads it, `ivt_f2_dim_dir(raw, k)` resolves dimension `k`’s block directory (`[u32 off][u16 len][u16 len]`, two indirection depths for big chunked geo dirs), self-validated against `n_entries`. Each directory lists that dimension’s codebook in logical order (dictionary/schema, member-id table, ordinals, the `81 02 02 00` doubled-name marker, EN then FR member blocks, footnotes). Readers: `ivt_f2_dim_dir_labels()`, `ivt_f2_dim_dir_ordinals()`, `ivt_f2_dir_footnotes()` (with `scope`/`dimension`/`member_id`; member notes flagged by an `84 01` bitmap, `ivt_f2_footnote_bitmap()`), `ivt_f2_table_footnotes()`. Other header slots: `ivt_f2_master_dir()` (`@544` → master directory at 992) and `ivt_f2_dqf_legend()` (`@712`, `[82 01]`-framed EN/FR per code A–E/R/P). `ivt_f2_dim_count_reconcile()` opens with `ivt_f2_dim_slot_declared()` (adopt the declared count/slots from the `16 00` slot table, quiet) before falling back to `ivt_f2_dim_slot_expand()`, and closes with `ivt_f2_dim_count_container()` (the page directory, `ivt_dir_outer_count()`). |
| `codebook-f2.R` | **the unified codebook.** `ivt_f2_geo_read(raw, full)` is the single geography dispatcher; `ivt_f2_geo_light()` (metadata default) and `ivt_f2_geographies()` (`geo_attributes = TRUE`) are thin wrappers. Stage 1 `ivt_f2_geo_entries()` locates the geo block directory once and exposes lazy memoized `records`/`strict`/`values` accessors shared by all six readers. Then an ordered specializer chain: flow → inline → schema → custom → bare; a complete uid array wins for big chunked DGUID tables; else Stage 3 `ivt_f2_geo_combined()` is the last-resort net (`canivt_geo_unparsed`, loud). Column identity is **metadata-driven** where declared — the `81 02` field dictionary (`ivt_f2_geo_field_schema()` + `ivt_f2_geo_field_roles()`) maps runs to `geo_name`/`geo_name_fr`/`geo_uid` by the file’s own field names; only without a matching dictionary does it fall to content heuristics. Readers: `ivt_f2_geo_simple()` (cheap names+DGUIDs, schema-addressed), `ivt_f2_geo_attributes()` / `ivt_f2_geo_attrs_dir()` (the **primary** attribute reader — every attribute read positionally, per group `[display + schema fields]` × EN-then-FR runs, ordinals dropped, per-member footnote text blobs skipped via `ivt_f2_dir_is_text_block()`; stride path `ivt_f2_geo_root_dir()` retained but unreached), `ivt_f2_geo_inline()` (combined-string blocks: `"name (code) [type] flag [(pct%)]"` for 1991/2006/2011/2016, and the code-first `"<code> - <name>"` of the Business-Register CD/CSD lineage; runs where no schema is declared **or** the declared one is a `custom` field dictionary naming the file’s own combined columns), `ivt_f2_geo_flow_dir()` / `ivt_f2_flow_sides()` (**origin-destination commuting flows**, geo type `0x0f`: a flow decodes as **two** geographies — the file’s POR/POW schema → `geo_res_*`/`geo_work_*`, pair kept as `geo_uid`; anchored on the uid array, labels joined back by code), `ivt_f2_dim_member_labels()` (data-dim labels via the doubled-name marker). Two loud name fills guarantee a `geo_name` for every member: `ivt_f2_inline_name_subtract()` and `ivt_f2_geo_fill_label()` (both fill NAs only). Snapshot-guarded by `fixtures/geo-snapshot.csv`. **Slugs** (`ivt_dim_slug()`) are generic: lower-cased leading word of the dimension name, made unique. Also the slot declarations: `ivt_f2_time_members()` (`08 00` time table, fed to the count reconcile by `ivt_f2_dim_time_declared()`) and `ivt_f2_dim_slot_table()` (the `16 00` block’s 22-bit per-slot records → `live`/`used`/`deleted`/`code_len`/`codes`/`codes_ok`), feeding `ivt_f2_dim_slot_alloc()`. |
| `read-f2.R` | **unified metadata + tidy**: `ivt_f2_metadata()`; `ivt_f2_vl_pairs()` + `ivt_f2_dim_name()` (header Variable List names, matched to the descriptor by count); `ivt_f2_dimensions()` (per-dim `name/count/type/is_geography/members`); `ivt_f2_footnotes()` (table + dimension + member notes, renumbered by `ivt_f2_footnote_finalize()`, each with `scope`/`dimension`/`member_id`/`member_refs`) + `ivt_f2_legacy_footnotes()` / `ivt_f2_note_refs()` (the legacy `(N)` markers in labels); `ivt_f2_tidy()`; `ivt_data_colnames()`. |
| `suba.R` | the **type-00 sub-A** provincial Business-Patterns module (`ivt_f2_suba_annotate()`): measures the non-declared directory stride from the page directory (`ivt_f2_suba_dir_stride()`, ignoring blank pages via `ivt_f2_page_blank()`), recovers the under-declared industry count from codebook chunks (`ivt_f2_suba_industry_codes()`) or from the bilingual member arrays (`ivt_f2_suba_member_arrays()`), and **commits only if the decode reconciles** (industry-Total == Σ detail, or Canada == Σ provinces) — else the file stays honestly UNSUPPORTED. Three placement cases: `dense`, `chunked` (contiguous run + total) and `sparse` (members == the occupied slots). Industry **labels are PROVISIONAL** (`canivt_suba_labels`, loud): reconciliation validates sums, not the code→member assignment. |
| `status.R` | **the page cell-status tail** — which absent cells are zeros and which are MISSING, and why. `ivt_page_status(raw, off, lay, size)` returns `kind ∈ {none, mask, status, unreadable}`; on `status` (the `0xa` array) it also returns per-cell `codes` at every declared width `W ∈ {1,2,4,8}` (`ivt_status_array()`), NULL only where the header does not parse. `ivt_status_scatter()` is the shared sparse rebuild both forms use. The tail is a **sparse array of value-width words addressed by an index bitmap occupying the WHOLE pre-value region** (the `b2` trailer + the `32·(b3−8)` head — so `b3` is in effect an index-size code), read pair-swapped MSB-first, one bit per word; gate `popcount(index)·width == tail length` (1,810,626/1,810,626 mask pages, 0 unreadable). Scattering the written words back to their indexed positions rebuilds the block; its first `rec_bytes` are the mask, read by `ivt_mask_bits()` — MSB-first and, uniquely in this container, **not pair-swapped** — at `lay$grid$bit`. Reports `nan_words` (x87-quieted NaN-shaped words: one status bit destroyed **in the source**), `extra_words` (the undecoded second block) and `covered_bits` = `min(index words, mask words)` — **the index’s reach, not the last word written**: an unwritten word the index *could* have addressed is the file declaring it all-zero, so only cells past the reach feed the `beyond` count (0 corpus-wide). Also `ivt_f2_status_legend()` — the table’s **own** reason-code legend from header slot `@698`: entry 0 is an index array `[04 02][u16 n_codes][u16 per_code]` + `n_codes·per_code` u32 entry indices (`per_code` 2 bilingual, 1 EN-only), each referenced record `[82 01|02 01][u16][flags][u8 sym_len][symbol][00][u16 len][text]`, symbol found by its promised NUL and text required only to *fit* (survey records append a second string). Returns `code`/`symbol`/`text_en`/`text_fr`, NULL where nothing declares; `IVT_STATUS_VOCAB` is the loud NDM-shaped fallback. Reached only via `ivt_decode(missing = TRUE)`. |
| `complete.R` | **the published table.** `ivt_complete_budget()` (the `canivt.max_cells` guard) and `ivt_complete_cells()` — assembles the full grid from `ivt_decode(complete = TRUE)`’s per-coordinate accumulators, maps reason codes to `symbol`/`status` **factors** through the file’s own `@698` legend (code `0` = value or published zero, `-1` = mask-derived “missing, reason unstated”, a code the legend does not name stays NA and is counted), and delegates the loud reporting to `ivt_status_report()` (decode.R, shared with `ivt_missing_cells()`). `ivt_flagged_cells()` is the `is.na(value)` view that fills `x$missing`. |
| `read.R` | public [`read_ivt()`](https://mountainmath.github.io/canivt/reference/read_ivt.md), [`ivt_metadata()`](https://mountainmath.github.io/canivt/reference/ivt_metadata.md), [`ivt_tidy()`](https://mountainmath.github.io/canivt/reference/ivt_tidy.md), `print.ivt` — one path for all families; `read_ivt(missing = TRUE)` adds `x$missing` (see `status.R`); `ivt_family()` detector + `ivt_is_supported()` gate. `ivt_tidy(dim_names=)` names columns by slug (default) or full label; `x$cells` always keeps slugs (the naming is an output-layer rename shared with [`ivt_members()`](https://mountainmath.github.io/canivt/reference/ivt_members.md)). `ivt_tidy(language=)` gives EN (default) or FR labels, falling back per column. **Parquet paths carry a language marker** (`<key>_en/_fr.parquet`); `ivt_members_path()` strips it so one `_members.parquet` sidecar serves both. [`ivt_parquet_language()`](https://mountainmath.github.io/canivt/reference/ivt_parquet_language.md), [`label_ivt_columns()`](https://mountainmath.github.io/canivt/reference/label_ivt_columns.md). Geography columns keep `geo_*` names; `geo_uid` is language-neutral. [`ivt_tidy_missing()`](https://mountainmath.github.io/canivt/reference/ivt_tidy_missing.md) is [`ivt_tidy()`](https://mountainmath.github.io/canivt/reference/ivt_tidy.md) for `x$missing` — same labelling, `value` replaced by `symbol`/`status` (FR wording swapped in from the legend), so the two tables line up column for column; `ivt_tidy(missing = TRUE)` binds them (missing cells as `value = NA` rows), which is the form to complete to a full grid from. |
| `stream.R` | **chunked conversion** — the published grid written a slice at a time, so a big table converts on a small machine. The fold is positional: the entry cartesian’s LAST column (the outermost paged dimension) varies slowest, so a slice of it is a contiguous run of output rows — `ivt_decode(outer = )` takes the 0-based member indices to walk and is otherwise the same decode. `ivt_chunk_plan(lay, max_cells)` splits that dimension into `getOption("canivt.chunk_cells", 5e6)`-row chunks (`list(NULL)` = one piece, which is also the only option when the layout has nothing outside the straddle window). `ivt_write_stream()` runs the loop — decode chunk → [`ivt_tidy()`](https://mountainmath.github.io/canivt/reference/ivt_tidy.md) → sink → drop — and **checks that the streamed row count equals the grid**, so a plan that failed to cover the table aborts rather than writing a short file. Two sinks (`ivt_sink_open/_write/_close`): Parquet via `ParquetFileWriter` (schema from the first chunk; stable because labels and the `symbol`/`status` factor levels are table-wide), CSV via ONE connection held open ([`gzfile()`](https://rdrr.io/r/base/connections.html) when the path ends `.gz`) so a chunked gzip is a single stream. The whole-table CSV path writes through the same sink, so the two files are identical by construction. `ivt_csv_path()` / `ivt_csv_missing_path()` / `ivt_csv_is_gz()` are the `.gz` naming rules. Validated cell-for-cell against the whole-table decode on every sliceable corpus table (`test-stream.R`); 98-10-0241 → Parquet peaks at 1.1 GB instead of 6.3 GB. |
| `collect.R` | **factor-level context**: `ivt_members(x)` (one row per tidy column × member with `member_id`/`ordinal`/`label`/`level`/`depth`); `collect_ivt(x, members)` converts dimension columns to factors whose levels are the **full** member list in ordinal order (filtered-out members stay as levels). Levels travel as a `<name>_members.parquet` sidecar. **Geography is never levelled** — it is an identity axis (`geo_uid` is the join key), its member list runs to tens of thousands, and its ordinal is a hierarchy traversal, not an analytic order; it was 99.7% of the sidecar. Per-member geography context lives in `metadata$geographies` instead, including the label hierarchy (`geo_depth`/`geo_parent_id`, added by `ivt_f2_metadata()`, omitted when the axis is flat). `ivt_factorize()` still filters `dimension == "Geography"` so an **older cached sidecar** cannot start factorizing `geo_uid`. Ordinals from `ivt_f2_dim_dir_ordinals()` (must be a permutation of `1..count`). `dim_names = "label"` applies on **every** path (on Arrow/Parquet by calling [`label_ivt_columns()`](https://mountainmath.github.io/canivt/reference/label_ivt_columns.md) after the factor conversion), and the result carries the `members` table + source `path` as attributes. `ivt_member_col_map()` resolves each member row to its column by written name **then** by the `dimension`/`dimension_fr` the member table records — so [`label_ivt_columns()`](https://mountainmath.github.io/canivt/reference/label_ivt_columns.md) composes with [`collect_ivt()`](https://mountainmath.github.io/canivt/reference/collect_ivt.md) in **either order**, label matches never claiming a column an exact match owns. Also the **cell-status sidecar**: `ivt_missing_path()` (which, unlike `ivt_members_path()`, KEEPS the `_en`/`_fr` marker — its coordinates and its `status` wording are language-specific) and public `ivt_missing(x)`, resolving from an `ivt`, a Parquet path or an Arrow/dplyr connection (attribute, then `path`, walking `$.data`). |
| `get.R` | `get_statcan_ivt(source, …)` — one-stop accessor. `source` = StatCan catalogue number, Borealis id/key/`file_id`, local custom id, a one-row catalogue tibble, or a named length-one `c(key = "url-or-path")`. Resolves → downloads → decodes → caches tidy Parquet → returns an [`arrow::open_dataset()`](https://arrow.apache.org/docs/r/reference/open_dataset.html) connection. `keep_ivt = FALSE` (default) discards the raw `.ivt`. `missing = TRUE` also decodes and caches the `_missing.parquet` sidecar, attached lazily as `attr(ds, "missing")`; a cached Parquet **without** one is re-decoded rather than silently answering with less. Also [`list_ivt_cache()`](https://mountainmath.github.io/canivt/reference/list_ivt_cache.md) and [`prune_ivt_cache()`](https://mountainmath.github.io/canivt/reference/prune_ivt_cache.md) (both sidecar kinds are infrastructure: filtered out of the listing, pruned when orphaned). |
| `ground-truth.R` | **internal** — scrapes the public B20/20 HTML viewer (`Rp-eng.cfm`) to build validation fixtures. `ivt_gt_viewer_url()`, `ivt_gt_slice()`, `ivt_ground_truth()`. Returns one row per cell with a `value` + per dimension a slug label and a 1-based `<slug>_id` **position** (the label-independent join key). |
| `write.R` | `ivt_write_parquet()/_csv()/_metadata()` (parquet also writes the `_members` sidecar; both write the `_missing` sidecar by default when `x$missing` is present — the data table holds only cells that HAVE a value, so without it completing the grid turns every suppressed cell into a zero). **Either writer takes a PATH instead of an `ivt`** and streams (`stream.R`). **CSV is gzipped by default** (`compress = TRUE`): the published grid repeats every label on every row, so it compresses ~20× (30.9 MB → 1.4 MB on 98-10-0066); the extension is the truth about the file (`.gz` appended when missing, a `.gz` path always compressed) and the path actually written is returned. Also `ivt_label_depth(labels, unit)` / `ivt_label_parent()` (indentation → hierarchy). The **spaces-per-level is not universally 2**: `ivt_label_indent_unit()` reads it off the label set as the gcd of the observed indents (the census-of-agriculture geography axis, `00040200`/`00040207`/`00040231`, indents ONE space per level over Canada/province/CAR/CD/CCS, which a fixed 2 collapses from five levels to three). Geography infers the unit; data dimensions keep the validated default of 2. |

## Key invariants (don’t regress)

The *rules*; the measurements and original bugs behind them are in
[`decode-history.md`](https://mountainmath.github.io/canivt/inst/notes/decode-history.md)
(“Invariant derivations”).

- **There is ONE decode pattern** (`decode.R`) — nest every dimension
  power-of-two-positionally, data dims innermost (descriptor order, last
  fastest), geography outermost. Each page carries a fixed **2048-bit
  (256-byte) presence record**; the same nesting describes the in-page
  bits **and** the 8-byte directory entries. **Exactly one dimension
  straddles** the 2048-bit boundary: its in-page part
  (`ipc = floor(2048/inner_block)`) stays in the bitmap, the rest
  becomes `window_count = ceil(count/ipc)` directory-paged windows;
  everything outside the straddle is positional in the directory. The
  “family” is just *which* dimension straddles — a data dim (former
  family 1) or geography (former family 2); `ivt_layout()$geo_in_page`
  is the discriminator. The walk never asks which dimension is geography
  (on the 1981 profile, geography is dim 3 and lands in the presence
  record).
- **All nesting geometry — presence-bit AND directory strides — pads
  each dimension to its DECLARED slot allocation**
  (`ivt_f2_dim_slot_alloc()`: the u16 opening the dimension’s
  `81 02 <alloc-u16> 16 00` member-code block or `08 00` time table),
  falling back to `nextpow2(extent)` only when the declaration cannot
  hold the members (chunked \>1024-member dims declare a block-local
  1024).
- **The bitmap addresses members by SLOT, and slots can have holes.**
  The survey generations’ time dimensions store a
  `81 02 <alloc-u16> 08 00` **time-series member table**
  (`ivt_f2_time_members()`, markers.md §E.1): a u16 slot capacity +
  `alloc` one-byte slot flags (**pair-swapped**; non-zero = populated) +
  one u24 LE date per member, right-aligned, **days since 0000-03-01**
  (labels are generated from the dates). Every other dimension declares
  the same thing in its `81 02 <alloc-u16> 16 00` block’s
  **mid-section** (`ivt_f2_dim_slot_table()`, markers.md §E.1a): `alloc`
  × **22-bit** slot records, pair-swapped and MSB-first, padded to an
  even byte count — bit 0 LIVE, bits 1..12 the member code’s length in
  unary, bit 18 an extra trailing code byte, all-zero = never allocated.
  It is trusted only when walking the codes it predicts consumes the
  following member-code array **byte-exactly** (`codes_ok`; live slot =
  `[u8 len][code]`, deleted slot = bare `L` code bytes with no prefix).
  `ivt_f2_dim_slot_declared()` then adopts the declared count and slot
  positions **quietly** — a declaration is not a fallback — from EITHER
  block: a dimension carries one or the other, never both, and where
  there is no `16 00` table `ivt_f2_dim_time_declared()` supplies the
  time table’s count/slots, gated on every populated slot resolving to a
  plausible date (`SP3_RHUXA9_801`’s “Date” declares 23 members against
  a descriptor count of 3386). `ivt_f2_dim_slot_expand()` is only the
  fallback where no table parses. When slots ≠ `1..count` the dim
  carries `$slots` (and `$slot_used` where the codebook arrays are
  used-slot-length), extents drive the geometry,
  `ivt_f2_cell_grid(pos=)` maps bits to slots, and a value at a deleted
  slot warns `canivt_slot_hole`. **The declared slot map also addresses
  the CODEBOOK member arrays**, not only the presence bitmap and the
  member-code array: a label array may be written one record per
  allocated slot, empty at the rest, so an interior hole defeats the
  trailing-NA trim. `ivt_f2_dir_member_arrays(slots=)` accepts such a
  run as `v[slots]` — but only when `which(!is.na(v))` is *exactly* the
  declared slots, so a coincidentally-long array can never be re-indexed
  (`Table_6_c-2009`: alloc 256, 225 members, used slots 1..107,
  109..226).
- Presence bytes are **pair-swapped** (`bitwXor(i, 1)`) and read
  **MSB-first**; the value stream is **not** swapped.
- **Value run start** = `4 + presence_len + trailer(b2) + 32·(b3 − 8)`
  (`presence_len = rec_bytes × geos_per_page`), from the marker
  (`ivt_value_trailer(b0, b2, b3)`): trailer = `b2 == 0x00` → 0, else
  `2·(b2 >> 4) + 2·(low nibble(b2) > 0)`; head = `32·(b3 − 8)`,
  `b3 ∈ {08..0e}`. Unknown markers **abort** (`canivt_unknown_marker`);
  valid entries pointing at them are skipped loudly
  (`canivt_skipped_pages`). Every page is extent-checked against its
  directory entry’s u16 size, with **equality only when `b2 == 0` and
  `b3 == 08`** (pages with a head block append the cell-status tail, so
  only `≤` applies; `canivt_page_overrun`). Decoding stays
  presence-authoritative (exactly `popcount` values from the run start),
  so a tail never affects it.
- **The pre-value region is not padding — it is the tail’s INDEX**
  (`status.R`): the whole `trailer + head` span is a bitmap, one bit per
  value-width word of the trailing cell-status block, so `b3` is
  effectively an index-size code. Gate
  `popcount(index)·width == tail length`. Read only under
  `missing = TRUE`; it can never move a value.
- The page marker’s **low nibble is the value-width code**
  (`0x8`→float64, `0x4`→int32, `0x2`→int16); the high nibble (`0x8` vs
  `0xa`) changes the pad/`0xFF` trailer length **and selects the page’s
  trailing cell-status block** — `0x8` → a bare 1-bit absent mask (a
  *subset* of the absent cells: masked ⇒ genuine zero, unmasked ⇒
  missing), `0xa` → the self-describing status array that carries the
  `x`/`...` reason codes. The correlation is exact over the sampled
  corpus, so `0xa` **is** a suppression-bearing flag after all (the old
  note here said otherwise). A **zero high nibble in b0 is the DENSE
  page variant** (1991 profiles): bytes 3–4 are a u16 value COUNT, one
  value per grid position, zeros stored literally, exact fit
  `4 + count·width == size` (`ivt_decode_page_dense()`).
- Directory entries are in **geography member-id order**; geos-per-page
  is **computed** (`geo_count / n_pages`), never assumed. Legacy index
  stride `0x1000` → 166 geographies on the reference table (directory
  `n` → Member ID `n+1`).
- Member id columns in `cells` are **1-based** (match StatCan Member
  IDs); the CSV ground-truth `Coordinate` is also 1-based.
- The header dir pointer **`@558` stores only the LOW 16 BITS** of the
  directory offset — `ivt_idx0()` unwraps it (smallest `+ k·65536` whose
  entry validates). The page-directory entry floor is **1024**.
- **A directory BASE may open with unwritten entries.** The directory
  pads every level to its declared allocation, so entry 0 of a correct
  base can legitimately be an all-zero record (96 of them on
  `Table-080`) — the sparse-directory rule applied one level up.
  `ivt_f2_dir_first_entry()` walks up to `IVT_DIR_LEAD_BLANK_MAX` (1024)
  blanks (`ivt_dir_entry_blank()`) before declining, bounded so header
  padding cannot be walked into an unrelated page marker;
  `ivt_f2_dir_anchor_header()` runs the **strict pass across every wrap
  first**, so a blank-led candidate can never beat a populated one. **A
  failed anchor is not evidence of a stale pointer** — on all five files
  once blamed on `@558`, the pointer was right.
- **`ivt_f2_descriptor_impl()`’s `descriptor_from_slots` early return
  reconciles too.** The rebuild sizes each dimension from its codebook;
  only `ivt_f2_dim_count_reconcile()` reads the file’s declaration of
  **where** those members sit, so skipping it drops `$slots` for any
  dimension whose `16 00` block declares **live slots above 1**
  (`Table-080`’s “Sex” at slots 4..6 of 8 → 0 cells decoded;
  `table_5_c-ivt-2008`’s “Offences”, 215 live slots at 1..216 with a
  hole at 98 → silently misassigned members and one dropped).
- **A chunk run may carry a LEADING partial, not only a trailing one.**
  `ivt_f2_slot_chunked_count()` pins the tail on a single trailing
  partial; when that declines, `ivt_f2_slot_chunk_multiset()` takes the
  general form — the multiset of member-array lengths must partition
  into `R` **identical** runs (`R` = gcd of the multiplicities, required
  ≥ 2, i.e. a bilingual codebook), and the per-copy count is the
  size-weighted sum. `PROVSIC4dec1997`’s SIC-4 industry codebook is
  `[94][256][256][256][256][137]` = 1,255. LOUD
  (`canivt_chunked_count`); only ever reached when the trailing-partial
  rule declines, so no existing verdict moves.
- **In the type-00 sub-A cluster the outer directory stride is
  non-declared (no file in the cluster has a `16 00` slot table at all),
  so an unmeasurable stride is a REFUSAL.** It is measured as a
  **TILING, not a progression** — a progression assumes the run starts
  at window 0, and `PROVSIC4dec1997` lays 11 windows per province at
  entry slots 3..13 of a 16-slot group. `ivt_f2_suba_dir_stride()` takes
  the smallest `S` for which the populated entries fall into `geo_count`
  groups with an **identical residue set** and nothing is populated
  beyond `geo_count · S` (that clause separates a real stride from a
  divisor of it), tolerating a couple of wholly-empty groups
  (whole-geography suppression). It returns the window residues too, and
  **those gate the early return**: a file may stride exactly as the
  positional model does yet reach past the model’s window enumeration,
  which drops members silently. When no stride confirms, the geometry is
  unverified, `ivt_f2_suba_annotate()` sets `suba_unverified` and
  `ivt_f2_decodable()` returns `FALSE`. A single outer member
  (`EDDTAB16`) has no periodicity to measure and is left alone.
  Placements — including the **detached total** (total alone in window
  0, detail run right-aligned) — are always adopted on **exact
  reconciliation**, never on shape.
- **A written page whose presence record is all zero is an ABSENCE, not
  a witness** (`ivt_f2_page_blank()`). It carries no cells, so it says
  nothing about where the members sit — the same absence as an unwritten
  entry slot, one level down. Such entries are counted out of the sub-A
  tiling measurement: `PRVNAIC1dec1998` writes three stubs (window slot
  8, provinces 5/6/12; size 260 = marker + 256-byte presence + no
  values) that otherwise make those groups’ residue sets ragged so that
  **no** stride confirms.
- **Sub-A members need not be contiguous.** Where the codebook’s
  **bilingual** member arrays (`ivt_f2_suba_member_arrays()`: directory
  order, EN/FR pairs, each pair trusted only as far as the two copies
  agree in length) and the count of occupied slots agree, the members
  ARE the occupied slots in ascending order — nothing left to guess.
  `PRVNAIC1dec1998` puts 20 NAICS sectors at slots 1..20 and `Total` +
  `00 - Not Classified` alone in window 10 at 1363/1364. Its members
  cannot be counted by code (`31-33`, `44-45`, `48-49` are NAICS
  **ranges**, not numeric tokens), so this path never parses codes.
  Gate: **exactly one** slot equals the sum of all the others over every
  group, **and** its codebook label is the total — the only LABEL check
  in `suba.R`.
- **`ivt_f2_decodable()` = descriptor + layout +
  `ivt_page_preflight()`** — the whole detection gate. The pre-flight
  checks extent within the entry size, exact fit for `b2 == 0` pages,
  presence count ≤ the page’s real cell capacity, and that the directory
  **spans the outer entry cartesian**. A rejection often means **the
  descriptor was misread**, not that the container is alien. **The gate
  always returns a verdict**: entry indices are computed in double and
  screened by `ivt_entry_addressable()` (entries are 8 bytes at
  `idx0 + 8L·k`, so anything above `(int.max − idx0) %/% 8` is
  unrepresentable ⇒ misread descriptor ⇒ clean `FALSE`), never an
  integer-overflow `NA` that surfaces as an error.
- **`ivt_f2_descriptor()` anchors dimension records on the doubled
  name**, not a fixed `<type> 01 <upper>` marker: each record stores its
  name twice after a `0x01`, the **first copy may be truncated** (~14
  chars; longest matching prefix wins), and the name may start with an
  uppercase letter **or a digit**. The type byte is a
  storage/classification tag, **not** dimension identity. The header
  **`n_dim` field is unreliable** — gate on `length(d$dims)`. Handles
  the **INVERTED layout** (records before the `81 01 20 00 … 80 03`
  signature) and **PROSE-BLEED names** (2001 F-series: two
  count-anchored fallbacks in `ivt_f2_descriptor_name()`).
- **Double-01 descriptor records are ambiguous — counts are reconciled
  against the codebook** (`ivt_f2_dim_count_reconcile()`):
  `[type][count][01][01]` is shared by the reference-period record
  (“Year (2)”: `0e 02 01 01`) and the profile “Values” placeholder
  (`00 20 01 01`, real count 1). The dimension’s slot-directory member
  block decides; the same reconcile adopts a chunk-run count wherever it
  exceeds the descriptor’s (chunked \>256-member dims).
- **The declared slot allocation is the SECOND count witness.** On every
  validated table `alloc <= 2·nextpow2(count)`; a dimension allocating
  **more than `4·nextpow2(count)`** is declaring more members than the
  descriptor was read to hold. `ivt_f2_dim_count_reconcile()` then
  adopts the codebook member array’s own length
  (`ivt_f2_dir_member_count()`) when it lies strictly between the
  descriptor count and the allocation — the array LENGTH, never the
  allocation, so a merely over-allocated dim (accs “Offences”: 40
  members, 64 slots) never fires. LOUD (`canivt_underdeclared_count`).
  Runs before the double-01 pass and covers double-01 records (the
  SLID-era income lineage’s `1e 05 01 01` geography, real count 30).
- **The page directory is the THIRD count witness, and the last word**
  (`ivt_dir_outer_count()`, decode.R; `ivt_f2_dim_count_container()`
  runs it at the end of `ivt_f2_dim_count_reconcile()`). It builds the
  layout the descriptor
  - codebook counts imply, walks the **outermost paged dimension**
    across its own allocated capacity and extends the count to the last
    member whose entry **decodes AND carries cells**
    (`CDCSDNAIC3dec2006`: 5,914 declared, 5,927 real). It needs ≥ 2
    paged levels (with one, entries count *windows*, not members),
    declines where the dimension has slot holes, never stops at the
    first gap (an empty geography is a real member), and stops at any
    offset that is not a page so it cannot run into the codebook. Only
    ever raises. LOUD (`canivt_container_count`).
- **A “sparse” directory is a correct directory read against a wrong
  count.** The directory pads outer levels to `nextpow2()` like
  everything else, and an unwritten window is a zero entry — the same
  absence as a suppressed geography. The Business-Register CD/CSD tables
  allocate 16 entry slots per geography (`nextpow2(11 windows)` for
  their 1,366-member NAICS dim) and populate only slot 0; the referenced
  pages are byte-contiguous, so nothing is hiding. **The stride
  witnesses the count**: 16 slots per outer member declares an 11-window
  dimension.
- **A count of exactly 256 from a REBUILT descriptor is a chunk cap, not
  a count.** When the doubled-name walk loses too many records (2001
  prose-bleed) the descriptor is rebuilt from the header slot table,
  which sizes each dimension from its codebook member array — chunked at
  256 members per block. The record itself is still present and its
  count field still correct, so `ivt_f2_desc_declared_count()` re-finds
  it **by name**: `[u16 count][type][01]<name>`, `type` restricted to
  the u16-count storage tags (only they can declare \> 255) and the
  count required to resolve **uniquely**. Wired into both rebuild paths
  (`ivt_f2_dims_from_slots()` **and** `ivt_f2_descriptor_from_slots()`)
  and strictly one-directional — it RAISES a chunk-capped count, never
  lowers a good one. LOUD (`canivt_declared_count`). The container is
  the independent witness: with the right count the directory’s outer
  entry cartesian equals the page count exactly.
- **An ordinal run indexes members, so it cannot exceed the member
  count.** `ivt_f2_is_ordinal(t, n)` takes that bound where a count is
  in hand. Without it a chunk of geographically consecutive numeric
  CODES (2001 DAs: `35210433, 35210434, …`) reads as an ordinal
  delimiter, and dropping two such blocks left `ivt_f2_geo_inline_dir()`
  short of the chunk-group geometry — pushing geography onto the
  dedup/regex scan, which reassembles chunks out of order (labels
  shifted by 512 against correct values).
- **Geography is the first descriptor dimension EXCEPT the profile
  lineage** (`ivt_f2_geo_dim_index()` — 97-570-X1981004 / 98F0172X /
  95F0170X put a 1-member “Values” placeholder first and geography
  LAST). Dim 1 is the fast path; only when dim 1 has a single member are
  the slot directories probed for a geography signature. Identification
  is **never by type byte**: the geography descriptor *type* is a
  **storage-width tag** for the member count — `ivt_f2_descriptor()`
  reads **u16** for `0x10`/`0x0d`/`0x0a`/`0x0c`/`0x09`/`0x0f`, **u8**
  otherwise (`0x09` = a \>256-member *data* dim; `0x0f` = the 2011 NHS
  commuting-flow geography). `ivt_f2_data_dims()` = all dims except the
  geography index. Use `ivt_f2_geo_count()` (descriptor record), **not**
  `ivt_f2_header_geo_count()`, for any geography sizing.
- A **reference-period / facet** dimension (type `0x0e`) is **not**
  geography-folded: in 98-10-0077 *Year* is the innermost in-page
  dimension.
- `cells` data columns are named by a purely generic, **name-agnostic
  slug** (`ivt_dim_slug()`); columns stay in descriptor order, so `geo`
  need not be first. **No code branches on dimension names or type
  bytes** — everything the decoder needs is structural (positions,
  counts, the 2048-bit cap). Labels come from the codebook at `tidy`
  time.
- **Fallbacks are LOUD** (`ivt_fallback()`): every content-heuristic
  path (stride walks, regex/dedup scans, count-keyed labels, marker-scan
  directory location, fixed slot orders, tail windows) raises a classed
  `canivt_fallback` warning when it supplies values; `canivt.strict`
  upgrades these (and skipped pages) to errors. Detection probes stay
  quiet (`ivt_quietly()`). Wire every new fallback through it.

## Dev workflow

Integration tests need real `.ivt` files and auto-skip without them:

| env var | file (fallback path) |
|----|----|
| `CANIVT_SAMPLE_IVT` | `98100241.ivt` (`~/projects/censusmapper-import/data/raw/98100241/`) |
| `CANIVT_SAMPLE_IVT_F2` | `98100023.ivt` (`/tmp/t23/`) |
| `CANIVT_SAMPLE_IVT_F2_4D` | `98100129.ivt` (`/tmp/t129/`) |
| `CANIVT_SAMPLE_IVT_1991` | `1003011.IVT` |

**The corpus regression ledger** (`tests/testthat/test-corpus.R` +
`fixtures/corpus-ledger.csv`) runs the whole local corpus (one folder
per table under `CANIVT_IVT_CACHE`) through
[`read_ivt()`](https://mountainmath.github.io/canivt/reference/read_ivt.md)
and asserts, per table: the `ivt_is_supported()` verdict, strict-mode
cleanliness (`strict_clean = FALSE` rows are the KNOWN fallbacks — they
must *warn*, not error, so both a vanished warning and a new failure
trip the test) and the exact non-zero cell count. 170 tables, ~366M
cells, so it is **opt-in**:

``` sh
CANIVT_CORPUS_TESTS=1 Rscript -e 'devtools::test(filter = "corpus")'
```

Both sweeps read with **`complete = FALSE`**: the ledgers are contracts
about the *store* (the file’s own stored-value count is what a decode
regression moves), and completing 4.3 billion corpus rows would be the
sweep’s cost rather than its subject.

`fixtures/status-ledger.csv` (`test-status.R`) is the same contract for
the cell-status tail — one row per corpus table,
`unreadable`/`contradictory` the two columns that must never move.
Re-measure it with `dev/msweep.R` (see `dev/README.md`), which also
produces the corpus status figures quoted in the notes.

`fixtures/complete-ledger.csv` (`test-complete.R`) is the contract for
the **fold** — the store-only ledgers cannot see it. Per table: the grid
size (`prod(counts)`, read off the layout alone, so it is checked even
where the table is too big to complete under the sweep budget) and, for
the 126 tables under it,
`rows`/`stored`/`zeros`/`flagged`/`symbolled`/`vsum`. `rows == grid` is
the assertion that catches an optimization quietly mislaying a page’s
zeros; `stored` is cross-checked against `corpus-ledger.csv`’s
`n_cells`. Re-measure with `dev/csweep.R`. `test-stream.R`’s corpus
sweep runs on the same ledger, decoding every sliceable table one outer
member at a time and requiring the concatenation to be the whole-table
decode.

When a gap is closed or a table onboarded, update the ledger row **and**
`inst/notes/coverage.md` in the same commit.

**The suite is parallel.** `Config/testthat/parallel: true` splits the
unit files across processes, and the three corpus sweeps — which each
loop over the whole ledger *inside one file*, so file-level splitting
cannot touch them — do their reads through `ivt_test_pmap()`
(`tests/testthat/helper-parallel.R`) in a pre-pass and then assert
**serially** over the collected results. `expect_*()` must never be
called from a forked child: testthat’s reporter is process-local, so a
child’s expectations are silently lost. A sweep’s worker therefore
captures its own errors and warnings (`ivt_test_capture()`) and returns
them as data. Workers default to half the physical cores (each holds a
whole decoded table — memory is the binding constraint, not CPU);
override with `CANIVT_TEST_CORES`, and `=1` restores the old serial
behaviour exactly.

`.ivt` and large `.csv` files are git-ignored; never commit them.

## Open tasks

The decoder, unified metadata, uniform geography parsing, the family-2
attribute table, commuting-flow decoding, footnote scope and geo-name
completeness are all **done**; the onboarding backlog is cleared
(2026-07-21). The `81 02 <alloc> 16 00` mid-section is **decoded**
(2026-07-25) — the file declares its live/deleted slots and member-code
lengths, so `ivt_f2_dim_slot_expand()` is now only a fallback. The `0xa`
array’s reason codes are **fully interpreted** (2026-07-27) — the file
declares its own legend at `@698`, so there are no uninterpreted codes
left. - **The SECOND tail block is NOT decoded** (opened 2026-07-27). On
8 corpus tables (`97-555` 11,463 words … `95f0491xcb01004` 3) index bits
address words **past** the mask’s `rec_bytes`. Content is packed flag
words (`0x3333`/`0x1111`/`0x33FF`/ all-ones, nibbles confined to
`{0,1,3,7,b,f}`, written in the page’s value type), but **not a per-cell
code array under any of 16 tested encodings** (best 3/400 pages;
`97F0007` 0/107 everywhere) and its size correlates with no per-cell
quantity. Two dead leads, recorded so they are not re-run: it does *not*
resemble the `0xa` `W = 4` form, and it is *not* the cause of
`97F0015X`’s implausible missing count (that is its mask stopping
early). Counted as `extra_words`, loud (`canivt_status_extra_block`).
See `ivt-format.md`, “The second tail block (OPEN)”. - **Mask
completeness caveats, reported not hidden.** A mask that stops short of
the grid is a **statement**, not a gap: the page’s word index can
address every word the grid spans on 1,810,626/1,810,626 corpus mask
pages, so an unwritten word inside its reach declares that word all-zero
(⇒ every absent cell it covers is missing). `covered_bits` is the
index’s reach and `canivt_status_beyond_mask` fires only past it — **0
corpus-wide** (it was 2,290,657 when measured against the last *written*
word). Validated semantically by `dev/mvalidate.R`, whose arithmetic
also closed the `97F0007` viewer discrepancy. 36 corpus tables write no
tail at all (65 write no mask page). The x87 sNaN artefact destroys one
status bit per NaN-shaped `width = 8` word **in the source file**
(`canivt_status_nan_quieted`, raised via `ivt_source_truncation()` so
strict keeps it a warning). - **type-00 sub-A industry labels are
PROVISIONAL** (`R/suba.R`) — reconciliation validates sums, not
code→member assignment, and no published ground truth exists. Manual
leaf-code evidence (855/855 populated members are SIC leaves at shift 0;
shifts ±1/±2 scatter 272–318 onto aggregate codes) supports the current
assignment but the parser deliberately does not run it, so the loud flag
stays. (On the sparse-slot path the TOTAL member’s label *is* verified
by the gate; the rest of the axis stays provisional.) The
`PROVSIC4dec1997` leading-window backlog item is **closed**
(2026-07-26): there is no `16 00` slot table anywhere in this cluster;
the directory’s own tiling is the witness, and four files onboarded.
`PRVNAIC1dec1998` followed the same day via the blank-page + sparse-slot
rules — **the corpus refusal ledger is now empty**
(`unsupported-formats.md`), with no gate relaxed to get there. -
**`Rcpp` fast path** — only if pure-R decode becomes a bottleneck (~5 s
for 7.5M cells is fine).

Two resolved behaviours are **accepted by design** (detail in
`decode-history.md`): source-side `DQF_NOTE` truncation (\>252 chars,
truncated by StatCan’s writer — surfaced via `dqf_note_truncated` + a
`canivt_source_truncation` warning that stays a warning under strict),
and synthetic-aggregate geographies whose `geo_uid` / `geo_level` are
genuinely absent and correctly stay `NA`.

## Provenance

The reverse-engineering started in a project on-boarding older census
data into CensusMapper; those import scripts seeded **canivt**.
