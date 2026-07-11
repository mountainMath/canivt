# Changelog

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
