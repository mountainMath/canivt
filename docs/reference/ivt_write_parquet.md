# Write an IVT table to Parquet

Write an IVT table to Parquet

## Usage

``` r
ivt_write_parquet(
  x,
  path = NULL,
  labels = TRUE,
  members = TRUE,
  dim_names = c("slug", "label"),
  language = "en",
  ...
)
```

## Arguments

- x:

  An `ivt` object from
  [`read_ivt()`](https://mountainmath.github.io/canivt/reference/read_ivt.md).

- path:

  Output `.parquet` path. Defaults to `<product_id>.parquet` in the data
  cache
  ([ivt_cache_dir("data")](https://mountainmath.github.io/canivt/reference/ivt_cache_dir.md),
  i.e. option `canivt.data_cache` or
  [`tempdir()`](https://rdrr.io/r/base/tempfile.html) when unset).

- labels:

  Passed to
  [`ivt_tidy()`](https://mountainmath.github.io/canivt/reference/ivt_tidy.md):
  write labelled columns (`TRUE`, default) or the compact integer-id
  table (`FALSE`).

- members:

  Also write the member-level table
  ([`ivt_members()`](https://mountainmath.github.io/canivt/reference/ivt_members.md))
  as a `<name>_members.parquet` sidecar next to `path` (`TRUE`,
  default), so
  [`collect_ivt()`](https://mountainmath.github.io/canivt/reference/collect_ivt.md)
  can convert dimension columns to full-level factors.

- dim_names:

  How to name the data-dimension columns (passed to
  [`ivt_tidy()`](https://mountainmath.github.io/canivt/reference/ivt_tidy.md)
  and the member sidecar): `"slug"` (default, the terse structural slug)
  or `"label"` (the full dimension name). Slug columns can be labelled
  on read with
  [`label_ivt_columns()`](https://mountainmath.github.io/canivt/reference/label_ivt_columns.md).

- language:

  Output language for labels and label-derived column names (passed to
  [`ivt_tidy()`](https://mountainmath.github.io/canivt/reference/ivt_tidy.md)):
  `"en"` (default) or `"fr"`. The member sidecar carries both languages
  regardless.

- ...:

  Passed to
  [`arrow::write_parquet()`](https://arrow.apache.org/docs/r/reference/write_parquet.html).

## Value

`path`, invisibly.
