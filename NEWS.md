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
