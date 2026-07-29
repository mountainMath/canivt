# Tidy the cell-status (missing-cell) table

The companion of
[`ivt_tidy()`](https://mountainmath.github.io/canivt/reference/ivt_tidy.md)
for `x$missing`: labels the coordinate columns exactly as
[`ivt_tidy()`](https://mountainmath.github.io/canivt/reference/ivt_tidy.md)
labels `x$cells`, so the two tables line up column for column and the
missing cells can be joined onto – or unioned with – the values.
Requires `read_ivt(path, missing = TRUE)`.

## Usage

``` r
ivt_tidy_missing(
  x,
  labels = TRUE,
  trim_labels = TRUE,
  dim_names = c("slug", "label"),
  language = "en",
  depth = FALSE
)
```

## Arguments

- x:

  An `ivt` object from
  [`read_ivt()`](https://mountainmath.github.io/canivt/reference/read_ivt.md).

- labels:

  If `TRUE` (default) replace member-id columns with member labels; if
  `FALSE` return the compact integer-id table (member ids).

- trim_labels:

  If `TRUE` (default) strip the hierarchy-indentation spaces from member
  labels.

- dim_names:

  How to name the data-dimension columns: `"slug"` (default) uses the
  terse structural slug (e.g. `age`), which is compact and
  language-neutral; `"label"` uses the full dimension name (e.g.
  `Age of primary household maintainer`, or its French equivalent when
  `language = "fr"`). Slug output can be labelled afterwards with
  [`label_ivt_columns()`](https://mountainmath.github.io/canivt/reference/label_ivt_columns.md).
  The choice applies to both `labels` values.

- language:

  Output language for labels and label-derived column names: `"en"`
  (default) or `"fr"`. Also accepts `"eng"`/`"fra"` and any case (it is
  lower-cased). French falls back to English wherever the file carries
  no French copy (e.g. the language-neutral `geo_uid`, or a dimension
  with no French name).

- depth:

  If `TRUE` (default `FALSE`) add a `<col>_depth` integer column after
  each data-dimension column giving that member's hierarchy depth (read
  from the label indentation, the same measure carried by
  [`ivt_members()`](https://mountainmath.github.io/canivt/reference/ivt_members.md)).
  Opt-in, so the default output – and hence the Parquet written by
  [`ivt_write_parquet()`](https://mountainmath.github.io/canivt/reference/ivt_write_parquet.md)
  – is unchanged.

## Value

A tibble: the coordinate columns of
[`ivt_tidy()`](https://mountainmath.github.io/canivt/reference/ivt_tidy.md),
then `symbol` and `status`.

## Details

The result has no `value` column (these cells have no value); in its
place are `symbol` and `status`, the reason the file states for the
absence, or `NA` where the page carries only the bare absent mask
(missing, cause not stated). The file's own reason-code legend rides
along as `attr(., "legend")`, and the per-page-class tally as
`attr(., "pages")`.

## See also

[`read_ivt()`](https://mountainmath.github.io/canivt/reference/read_ivt.md)
(the "Missing values" section),
[`ivt_write_parquet()`](https://mountainmath.github.io/canivt/reference/ivt_write_parquet.md),
which writes this table as a `_missing.parquet` sidecar.

## Examples

``` r
path <- system.file("extdata", "98100044.ivt", package = "canivt")
ivt <- read_ivt(path, missing = TRUE)
ivt_tidy_missing(ivt)
#> # A tibble: 0 × 8
#> # ℹ 8 variables: geo_label <chr>, geo_name <chr>, geo_uid <chr>,
#> #   geo_level <chr>, type <chr>, collective <chr>, symbol <chr>, status <chr>
```
