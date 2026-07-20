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
