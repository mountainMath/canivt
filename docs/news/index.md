# Changelog

## canivt 0.4.3

- **Breaking:**
  [`collect_ivt()`](https://mountainmath.github.io/canivt/reference/collect_ivt.md)
  no longer takes a `geography` argument, and
  [`ivt_members()`](https://mountainmath.github.io/canivt/reference/ivt_members.md)
  no longer emits geography rows. Geography is an identity axis rather
  than a category — `geo_uid` is the language-neutral key you join on,
  the member list runs to tens of thousands of entries on the large
  tables, and its ordinal is a hierarchy traversal rather than the
  analytic order that makes a data dimension worth levelling. The
  geography columns stay `character`. The geography rows were 99.7% of
  the `_members.parquet` sidecar (1.832 MB → 6 KB on the 1991 profile
  `1003011`). A sidecar written by an earlier version is still accepted;
  its geography rows are ignored rather than levelled.
- `metadata$geographies` gains `geo_depth` / `geo_parent_id`: the
  hierarchy implied by the display label’s indentation, as a depth and
  the `member_id` of each member’s nearest shallower ancestor. This is
  the one piece of per-member context the geography member rows uniquely
  held, now carried one row per geography rather than once per geography
  column. Both columns are omitted when the geography axis is flat, like
  any other column a vintage does not store.
- `ivt_label_depth()` / `ivt_label_parent()` gained a `unit` argument,
  and `ivt_label_indent_unit()` reads the spaces-per-level off the label
  set itself (the gcd of the observed indents) rather than assuming two.
  The census-of-agriculture geography axis (`00040200`, `00040207`,
  `00040231`) indents one space per level over Canada / province / CAR /
  CD / CCS, which a fixed unit of 2 collapsed into three levels, making
  each census division a sibling of the agricultural region containing
  it. Geography now infers the unit; data dimensions keep the validated
  default of 2.
- [`collect_ivt()`](https://mountainmath.github.io/canivt/reference/collect_ivt.md)
  honours `dim_names = "label"` on the Arrow / Parquet forms too
  (previously silently ignored there), and the result carries the member
  table it used and the source Parquet path as `members` / `path`
  attributes, so
  [`label_ivt_columns()`](https://mountainmath.github.io/canivt/reference/label_ivt_columns.md)
  composes with
  [`collect_ivt()`](https://mountainmath.github.io/canivt/reference/collect_ivt.md)
  in **either order**.

## canivt 0.4.0

- The page/presence nesting geometry is now driven by each dimension’s
  **declared member-slot allocation** (the u16 opening its codebook
  member-code block `81 02 <alloc-u16> 16 00` or time-series table
  `... 08 00`) instead of re-deriving `nextpow2(count)`. The two
  coincide on almost every table, but the declared value is
  authoritative: LFHR `Table-023`’s Hours dimension allocates 32 slots
  for 10 members, which *is* the formerly-mysterious “doubled-window”
  directory. The structural page-size probe (`ivt_survey_double()`) and
  its `canivt_survey_directory` fallback are retired; the table decodes
  byte-identically with no fallback, and the deferred `Table-024`
  record-packing puzzle is predicted by the same rule.
- English/French member-label attribution on the `04`-gen survey tables
  now reads the file’s own field dictionary: the declared
  `Description`/`Description_FRA` and `English`/`French|Français` column
  pairs (matched tolerant of field-struct byte bleed) join the
  previously recognized vocabularies, so the loud content-score language
  fallback no longer fires on any dimension with a declared pair.
- The bit-headed dense member-array reader accepts its pre-records
  marker as the structural single-bit-byte class rather than an
  enumeration; this parses Table-023’s English “Sex” block (marker
  `0x04`), fixing that dimension labelling French, and harmonizes the
  Business Patterns lineage (CBP 2008/2010 now expand the same deleted
  12th employment-size slot as CBP 2007/CDNAIC).

## canivt 0.3.0

- Cleared the 2026-07 onboarding backlog: a fresh random re-sample of
  the StatCan and Borealis catalogues surfaced 7 previously-unseen
  tables that did not read strict-clean; all 7 now decode, validated
  against external ground truth (accounting identities / published
  counts). Every `.ivt` in the corpus now decodes.
- Onboarded an earlier `02 00 20 00` container generation (provincial
  SIC establishment counts, `PRSIC1dec1999`): tolerates block
  directories with interior null holes, a `0x10`-marked dense member
  array, and the `English Label` / `Etiquette` schema vocabulary.
- Onboarded the UCR survey cross-tabulation lineage
  (`table_6_c-ivt-2007`), whose descriptor is stored inverted before a
  `…80 01` signature — rebuilt from the header slot table when the
  forward walk finds nothing.
- Geography of uid-less custom single-area extracts is now read directly
  from the file’s field dictionary instead of triggering a spurious
  DGUID byte-scan.
- Recovered several profile / F-series / 2006 census tables that
  previously failed the family gate (geography-last prose-bleed
  dimension names; page pre-flight relaxed for `b3 >= 9` pages carrying
  an allocation/mask tail).

## canivt 0.2.0

- Decodes the older `02 00 20 00` “split-definition survey” container
  generation alongside the modern `04 00 20 00` census/custom lineage —
  covers Health Statistics at a Glance (1999), the 1996 Census of
  Agriculture, and the 1996 Small Area Business survey. These tables
  have no geography dimension (a single area per file) and can carry a
  time-series reference dimension whose member labels are generated from
  an on-disk date table rather than a stored codebook.
- Onboards the Canadian Business Patterns lineage (Business Register
  establishment counts by dissemination area x NAICS x employment size).
- Onboards the 2016 custom cross-tabulation extract lineage
  (`CRO0163850` / `CRO0166131`), documented in a new “Onboarding custom
  IVT files” vignette.
- Geography for schema-less custom exports is now mapped through the
  file’s own field dictionary rather than a content heuristic,
  recovering two custom exports that previously fell back to verbatim
  labels.
- Added a byte-marker catalog (`inst/notes/markers.md`) and a
  self-checking test suite that fails if a newly-onboarded `.ivt` uses
  an undocumented marker.
- Fixed
  [`borealis_ivt_catalogue()`](https://mountainmath.github.io/canivt/reference/borealis_ivt_catalogue.md)
  erroring on search result pages that carry nested (non-atomic)
  columns.
- Expanded the corpus regression ledger and the `ivt-format` vignette /
  byte-format reference to document the new container generation.

## canivt 0.1.0

- Initial release.
- [`read_ivt()`](https://mountainmath.github.io/canivt/reference/read_ivt.md)
  decodes Statistics Canada Beyond 20/20 `.ivt` tables — both the data
  cells and the codebook (dimension members, geographic identifiers /
  DGUIDs, footnotes) — straight from the file bytes, with no companion
  CSV or metadata download. A single descriptor-driven decoder handles
  every vintage in the corpus (1981–2021 census tables, profiles,
  F-series, large crosstabs and commuting-flow tables).
- [`ivt_tidy()`](https://mountainmath.github.io/canivt/reference/ivt_tidy.md),
  [`ivt_metadata()`](https://mountainmath.github.io/canivt/reference/ivt_metadata.md),
  [`ivt_members()`](https://mountainmath.github.io/canivt/reference/ivt_members.md)
  and
  [`collect_ivt()`](https://mountainmath.github.io/canivt/reference/collect_ivt.md)
  produce labelled long tables, metadata and full-level factors.
- [`ivt_write_parquet()`](https://mountainmath.github.io/canivt/reference/ivt_write_parquet.md),
  [`ivt_write_csv()`](https://mountainmath.github.io/canivt/reference/ivt_write_csv.md)
  and
  [`ivt_write_metadata()`](https://mountainmath.github.io/canivt/reference/ivt_write_metadata.md)
  export the decoded table and codebook.
- [`get_statcan_ivt()`](https://mountainmath.github.io/canivt/reference/get_statcan_ivt.md),
  [`ivt_download()`](https://mountainmath.github.io/canivt/reference/ivt_download.md),
  [`statcan_ivt_catalogue()`](https://mountainmath.github.io/canivt/reference/statcan_ivt_catalogue.md)
  and the Borealis Dataverse helpers download and cache tables from
  their public sources.
- A small sample table (`inst/extdata/98100044.ivt`, StatCan
  98-10-0044-01) is bundled for examples and tests.
