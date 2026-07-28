# canivt 0.5.0

* **`read_ivt()` now returns the published table, not the store.** `x$cells`
  spans the whole grid — one row per real coordinate, the way StatCan's own CSV
  download publishes it — with the published zeros written out, flagged cells
  carrying `value = NA`, and two new factor columns, `symbol` and `status`,
  naming the reason the file states for each flagged cell. The rule is read off
  the file, never off a published CSV: *an absent cell is the published zero
  unless its page's cell-status block says otherwise*. A page that writes no
  tail is a page with nothing to flag; a page whose tail cannot be read has its
  absences published as zeros **and counted**, loudly
  (`canivt_absent_unclassified`).

  Validated cell-for-cell against StatCan's published CSVs on five tables
  covering every page class — 98-10-0040, 0019, 0021, 0478, 0655 — with every
  row present, no extra row, `max|difference| = 0` on every value and every
  published symbol matched. Corroborated independently by the WDS
  `nbDatapointsCube` count, which equals stored cells plus flagged cells on
  every sparse cube checked.

  `read_ivt(complete = FALSE)` restores the previous store-only output. Because
  completion multiplies the row count (~12× over the development corpus, far
  more on a sparse crosstab), it is refused above
  `getOption("canivt.max_cells", 1e8)` grid cells with a message naming the size
  and both ways forward.
* **`ivt_write_parquet()` and `ivt_write_csv()` convert a chunk at a time.**
  Hand either of them the *path* of an `.ivt` instead of an `ivt` object and the
  table is decoded, written and dropped one slice at a time, so the completed
  grid is never held whole — which is what makes converting a large table
  possible on a small machine. The fold is positional: the entry cartesian's
  outermost paged dimension varies slowest, so a slice of it is a contiguous run
  of output rows (`ivt_decode(outer = )`), and the chunk size is
  `getOption("canivt.chunk_cells", 5e6)` grid rows. The result is the same file:
  validated cell-for-cell against the whole-table decode on every sliceable
  corpus table, at the finest slice and at a multi-member plan. Converting
  98-10-0241 (39,154,752 published rows) to Parquet peaks at **1.1 GB instead of
  6.3 GB** for a byte-identical output. `get_statcan_ivt()` takes this path
  automatically.
* **`ivt_write_csv()` gzips by default.** The published table repeats every
  dimension's labels on every one of its grid rows, so it compresses about an
  order of magnitude — 30.9 MB → 1.4 MB on 98-10-0066, and the 39-million-row
  98-10-0241 lands at 185 MB — for a format `readr`, `arrow`, `pandas` and
  `duckdb` all open directly. The extension always tells the truth about the
  file: `.gz` is appended to a path that lacks it, a path that already ends in
  `.gz` is compressed regardless, and the path actually written is what is
  returned. `compress = FALSE` writes plain `.csv`. A chunked write is a single
  gzip stream, not concatenated members.
* **`read_ivt(missing = TRUE)` decodes which absent cells are genuine zeros and
  which are MISSING**, returning them as `x$missing` — a coordinate tibble
  shaped like `x$cells` minus `value`, with a per-page-class tally in
  `attr(x$missing, "pages")`. The store keeps only non-zero cells, so an absent
  cell is *either* a published zero or a missing value; the page's trailing
  cell-status block is the only thing that separates them, and **"absent means
  zero" is false in every vintage** — it merely looks true on tables that
  publish no missings. Reproduces the Beyond 20/20 viewer exactly on the 2001
  profile `97F0020XCB2001070` (344 missings over the 86 tail-bearing pages of
  geographies 1–13, none for Nunavut).
* The bytes between a page's presence record and its value run — the `b2`
  trailer plus the `32·(b3 − 8)` head, previously documented as padding — are
  the **index bitmap** for that trailing block, one bit per value-width word, so
  `b3` is in effect an index-size code. The gate is the length identity
  `popcount(index) · width == tail length`, which holds on all 1,810,626 mask
  pages of the development corpus with no unreadable and no contradictory page.
  Value decoding is unchanged and stays presence-authoritative: the tail is read
  separately, only under `missing = TRUE`, and can never move a value.
* **The `0xa` reason-code array is decoded too**, by the same rule. Its
  addressing looked lineage-specific for years; it was the block being read
  without the sparse rebuild, each table's dropped all-zero words shifting its
  codes by a different amount. Rebuild first and one rule covers the corpus: the
  gate passes on all 1,273,173 status-array pages, a cell that carries a value
  has code 0 on every one of them, and every one of the 166,965,381 grid
  positions the decoder independently computes as padding carries code 1.
* **The array's code width `W` is a storage choice, not a dialect**, so the codes
  are read at every width; `0` is always a value or a genuine zero, and `1` is
  *nothing here* — filler at a padded grid position, and the published symbol at
  a real cell, the grid deciding which.
* **What the codes MEAN is declared by the file, not by the format.** Header slot
  `@698` holds each table's own status legend — symbol plus bilingual wording,
  one record per code, in code order — and the corpus holds four vocabularies
  that are offset from each other, so no fixed table can serve them all. `x$cells`
  is untouched; `x$missing` gains `symbol` and `status` columns taken from the
  file's legend, and the legend itself rides on `attr(x$missing, "legend")`.
  Validated cell-exact against StatCan's published tables in **both** directions
  on ten of them (98-10-0002, 0010, 0013, 0023, 0040, 0128, 0129, 0478, 0655,
  0658): every published symbol is matched by a code count and no code is left
  without a symbol. All 47 corpus tables that write a reason-code array declare a
  legend, and none of them uses a code the legend does not name. 54 corpus tables
  report missing cells — sparse NDM crosstabs whose grid is mostly `...`, every
  one of those cells having previously read as a published zero.
* The feature is off by default because completeness is vintage-dependent, and
  every gap raises its own classed warning rather than being folded silently
  into the count: `canivt_status_legend` (the file declares no legend, so the
  built-in vocabulary stands in), `canivt_status_code_unknown` (a code the
  file's own legend does not name),
  `canivt_status_unread` (a status array whose header this reader does not
  recognise), `canivt_status_extra_block` (a second,
  undecoded tail array on eight corpus tables), `canivt_status_beyond_mask`
  (cells past the last mask word a page writes — unmasked for want of a word
  rather than by the file's statement), `canivt_status_unreadable`, and
  `canivt_status_nan_quieted` (a NaN-shaped mask word quieted by the writer's
  x87 load/store, which destroys one status bit in the source file; a warning
  even under `canivt.strict`, since it is source damage rather than a fallback).
* **The cell status now survives export.** An exported table carries only the
  cells that *have* a value, so on its own it cannot say which of the rest are
  zeros — anyone completing the grid fills a suppressed cell with `0`. New
  `ivt_tidy_missing()` labels the missing-cell table exactly as `ivt_tidy()`
  labels the values, so the two line up column for column;
  `ivt_write_parquet()` / `ivt_write_csv()` write it beside the data as a
  `<name>_missing.parquet` / `.csv` sidecar (default `missing = TRUE`, skipped
  when the table carries no status block); `get_statcan_ivt(missing = TRUE)`
  decodes and caches it, attaching a lazy connection as `attr(., "missing")`;
  and `ivt_missing()` returns it from any of those forms. Unlike the member
  sidecar this one keeps the language marker (`<key>_en_missing.parquet`),
  because its coordinates — and the wording of `status` — are language-specific.
* `ivt_tidy(x, missing = TRUE)` returns the two together instead: the missing
  cells appended as `value = NA` rows, with `symbol`/`status` columns. That is
  the form to use when the result will be completed to a full grid, since an
  absent row is otherwise indistinguishable from a published zero. The writers
  keep the sidecar rather than this merged form by default, so exporting a
  sparse crosstab does not multiply the table by its absences.

# canivt 0.4.3

* **Breaking:** `collect_ivt()` no longer takes a `geography` argument, and
  `ivt_members()` no longer emits geography rows. Geography is an identity axis
  rather than a category — `geo_uid` is the language-neutral key you join on,
  the member list runs to tens of thousands of entries on the large tables, and
  its ordinal is a hierarchy traversal rather than the analytic order that makes
  a data dimension worth levelling. The geography columns stay `character`. The
  geography rows were 99.7% of the `_members.parquet` sidecar (1.832 MB → 6 KB
  on the 1991 profile `1003011`). A sidecar written by an earlier version is
  still accepted; its geography rows are ignored rather than levelled.
* `metadata$geographies` gains `geo_depth` / `geo_parent_id`: the hierarchy
  implied by the display label's indentation, as a depth and the `member_id` of
  each member's nearest shallower ancestor. This is the one piece of per-member
  context the geography member rows uniquely held, now carried one row per
  geography rather than once per geography column. Both columns are omitted when
  the geography axis is flat, like any other column a vintage does not store.
* `ivt_label_depth()` / `ivt_label_parent()` gained a `unit` argument, and
  `ivt_label_indent_unit()` reads the spaces-per-level off the label set itself
  (the gcd of the observed indents) rather than assuming two. The
  census-of-agriculture geography axis (`00040200`, `00040207`, `00040231`)
  indents one space per level over Canada / province / CAR / CD / CCS, which a
  fixed unit of 2 collapsed into three levels, making each census division a
  sibling of the agricultural region containing it. Geography now infers the
  unit; data dimensions keep the validated default of 2.
* `collect_ivt()` honours `dim_names = "label"` on the Arrow / Parquet forms
  too (previously silently ignored there), and the result carries the member
  table it used and the source Parquet path as `members` / `path` attributes, so
  `label_ivt_columns()` composes with `collect_ivt()` in **either order**.

# canivt 0.4.0

* The page/presence nesting geometry is now driven by each dimension's
  **declared member-slot allocation** (the u16 opening its codebook member-code
  block `81 02 <alloc-u16> 16 00` or time-series table `... 08 00`) instead of
  re-deriving `nextpow2(count)`. The two coincide on almost every table, but
  the declared value is authoritative: LFHR `Table-023`'s Hours dimension
  allocates 32 slots for 10 members, which *is* the formerly-mysterious
  "doubled-window" directory. The structural page-size probe
  (`ivt_survey_double()`) and its `canivt_survey_directory` fallback are
  retired; the table decodes byte-identically with no fallback, and the
  deferred `Table-024` record-packing puzzle is predicted by the same rule.
* English/French member-label attribution on the `04`-gen survey tables now
  reads the file's own field dictionary: the declared
  `Description`/`Description_FRA` and `English`/`French|Français` column pairs
  (matched tolerant of field-struct byte bleed) join the previously recognized
  vocabularies, so the loud content-score language fallback no longer fires on
  any dimension with a declared pair.
* The bit-headed dense member-array reader accepts its pre-records marker as
  the structural single-bit-byte class rather than an enumeration; this parses
  Table-023's English "Sex" block (marker `0x04`), fixing that dimension
  labelling French, and harmonizes the Business Patterns lineage (CBP 2008/2010
  now expand the same deleted 12th employment-size slot as CBP 2007/CDNAIC).

# canivt 0.3.0

* Cleared the 2026-07 onboarding backlog: a fresh random re-sample of the
  StatCan and Borealis catalogues surfaced 7 previously-unseen tables that did
  not read strict-clean; all 7 now decode, validated against external ground
  truth (accounting identities / published counts). Every `.ivt` in the corpus
  now decodes.
* Onboarded an earlier `02 00 20 00` container generation (provincial SIC
  establishment counts, `PRSIC1dec1999`): tolerates block directories with
  interior null holes, a `0x10`-marked dense member array, and the
  `English Label` / `Etiquette` schema vocabulary.
* Onboarded the UCR survey cross-tabulation lineage (`table_6_c-ivt-2007`),
  whose descriptor is stored inverted before a `…80 01` signature — rebuilt
  from the header slot table when the forward walk finds nothing.
* Geography of uid-less custom single-area extracts is now read directly from
  the file's field dictionary instead of triggering a spurious DGUID byte-scan.
* Recovered several profile / F-series / 2006 census tables that previously
  failed the family gate (geography-last prose-bleed dimension names; page
  pre-flight relaxed for `b3 >= 9` pages carrying an allocation/mask tail).

# canivt 0.2.0

* Decodes the older `02 00 20 00` "split-definition survey" container
  generation alongside the modern `04 00 20 00` census/custom lineage —
  covers Health Statistics at a Glance (1999), the 1996 Census of
  Agriculture, and the 1996 Small Area Business survey. These tables have
  no geography dimension (a single area per file) and can carry a
  time-series reference dimension whose member labels are generated from an
  on-disk date table rather than a stored codebook.
* Onboards the Canadian Business Patterns lineage (Business Register
  establishment counts by dissemination area x NAICS x employment size).
* Onboards the 2016 custom cross-tabulation extract lineage (`CRO0163850`
  / `CRO0166131`), documented in a new "Onboarding custom IVT files"
  vignette.
* Geography for schema-less custom exports is now mapped through the
  file's own field dictionary rather than a content heuristic, recovering
  two custom exports that previously fell back to verbatim labels.
* Added a byte-marker catalog (`inst/notes/markers.md`) and a
  self-checking test suite that fails if a newly-onboarded `.ivt` uses an
  undocumented marker.
* Fixed `borealis_ivt_catalogue()` erroring on search result pages that
  carry nested (non-atomic) columns.
* Expanded the corpus regression ledger and the `ivt-format` vignette /
  byte-format reference to document the new container generation.

# canivt 0.1.0

* Initial release.
* `read_ivt()` decodes Statistics Canada Beyond 20/20 `.ivt` tables — both the
  data cells and the codebook (dimension members, geographic identifiers /
  DGUIDs, footnotes) — straight from the file bytes, with no companion CSV or
  metadata download. A single descriptor-driven decoder handles every vintage in
  the corpus (1981–2021 census tables, profiles, F-series, large crosstabs and
  commuting-flow tables).
* `ivt_tidy()`, `ivt_metadata()`, `ivt_members()` and `collect_ivt()` produce
  labelled long tables, metadata and full-level factors.
* `ivt_write_parquet()`, `ivt_write_csv()` and `ivt_write_metadata()` export the
  decoded table and codebook.
* `get_statcan_ivt()`, `ivt_download()`, `statcan_ivt_catalogue()` and the
  Borealis Dataverse helpers download and cache tables from their public sources.
* A small sample table (`inst/extdata/98100044.ivt`, StatCan 98-10-0044-01) is
  bundled for examples and tests.
