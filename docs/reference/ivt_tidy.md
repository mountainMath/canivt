# Tidy an `ivt` object into a labelled data frame

Joins the decoded cells to the codebook so each dimension column holds
its member label (and geography gains a `dguid` column), producing a
long table analogous to the StatCan CSV download.

## Usage

``` r
ivt_tidy(
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
  Opt-in, so the default output — and hence the Parquet written by
  [`ivt_write_parquet()`](https://mountainmath.github.io/canivt/reference/ivt_write_parquet.md)
  — is unchanged.

## Value

A tibble.
