# Write an IVT table to CSV

Write an IVT table to CSV

## Usage

``` r
ivt_write_csv(
  x,
  path = NULL,
  labels = TRUE,
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

  Output `.csv` path. Defaults to `<product_id>.csv` in the data cache
  ([ivt_cache_dir("data")](https://mountainmath.github.io/canivt/reference/ivt_cache_dir.md)).

- labels:

  Passed to
  [`ivt_tidy()`](https://mountainmath.github.io/canivt/reference/ivt_tidy.md):
  write labelled columns (`TRUE`, default) or the compact integer-id
  table (`FALSE`).

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

  Passed to the CSV writer
  ([`readr::write_csv()`](https://readr.tidyverse.org/reference/write_delim.html)
  if available, else
  [`utils::write.csv()`](https://rdrr.io/r/utils/write.table.html)).

## Value

`path`, invisibly.

## Examples

``` r
path <- system.file("extdata", "98100044.ivt", package = "canivt")
ivt <- read_ivt(path)
out <- ivt_write_csv(ivt, file.path(tempdir(), "98100044.csv"))
file.exists(out)
#> [1] TRUE
```
