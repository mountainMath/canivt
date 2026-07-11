# Collect IVT data with dimension columns as factors

Like
[`dplyr::collect()`](https://dplyr.tidyverse.org/reference/compute.html),
but converts each labelled dimension column into a factor whose levels
are the table's **full** member list in codebook member-ordinal order –
so members filtered out of the collected rows are still visible as
factor levels, and members always sort in their StatCan order rather
than alphabetically.

## Usage

``` r
collect_ivt(
  x,
  members = NULL,
  geography = FALSE,
  dim_names = c("slug", "label"),
  language = NULL,
  ...
)
```

## Arguments

- x:

  An `ivt` object, an Arrow dataset / dplyr-on-Arrow query, or a
  `.parquet` path.

- members:

  A level table from
  [`ivt_members()`](https://mountainmath.github.io/canivt/reference/ivt_members.md);
  when `NULL` it is located from `x` (an attached `members` attribute,
  or the Parquet's `_members.parquet` sidecar).

- geography:

  Also convert the geography columns (`geo_label`, `geo_name`,
  `geo_uid`, `geo_level`) to factors. Default `FALSE`: large tables
  carry tens of thousands of geographies, which makes for unwieldy
  factor levels.

- dim_names:

  For `ivt` objects, how to name the data-dimension columns (passed to
  [`ivt_tidy()`](https://mountainmath.github.io/canivt/reference/ivt_tidy.md)
  and
  [`ivt_members()`](https://mountainmath.github.io/canivt/reference/ivt_members.md)):
  `"slug"` (default) or `"label"`. Ignored for the Arrow / Parquet
  forms, where the column names are already fixed by how the Parquet was
  written.

- language:

  Factor-level language: `"en"` or `"fr"`. `NULL` (default) auto-detects
  – `"en"` for `ivt` objects, and for the Arrow / Parquet forms the
  language marker in the file name (see
  [`ivt_parquet_language()`](https://mountainmath.github.io/canivt/reference/ivt_parquet_language.md)).
  For `ivt` objects it is passed to
  [`ivt_tidy()`](https://mountainmath.github.io/canivt/reference/ivt_tidy.md)/[`ivt_members()`](https://mountainmath.github.io/canivt/reference/ivt_members.md);
  for the Arrow / Parquet forms it selects the French `level_fr` from
  the sidecar as the factor levels.

- ...:

  For `ivt` objects, passed to
  [`ivt_tidy()`](https://mountainmath.github.io/canivt/reference/ivt_tidy.md).

## Value

A tibble with the dimension columns converted to factors.

## Details

`x` can be an `ivt` object from
[`read_ivt()`](https://mountainmath.github.io/canivt/reference/read_ivt.md),
the Arrow dataset returned by
[`get_statcan_ivt()`](https://mountainmath.github.io/canivt/reference/get_statcan_ivt.md)
(optionally after `dplyr` verbs such as
[`filter()`](https://dplyr.tidyverse.org/reference/filter.html)), or a
path to a Parquet written by
[`ivt_write_parquet()`](https://mountainmath.github.io/canivt/reference/ivt_write_parquet.md).
For the Arrow / Parquet forms the member levels come from the
`<name>_members.parquet` sidecar written alongside the data (or pass
`members` explicitly, e.g. from
[`ivt_members()`](https://mountainmath.github.io/canivt/reference/ivt_members.md)).
Works on both the labelled table and the compact integer-id table
(`labels = FALSE`), where the member-id columns are mapped to their
labels while being converted.
