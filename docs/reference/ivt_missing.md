# Get the cell-status (missing-cell) table

The one accessor for "which of the cells this table does not carry are
missing rather than zero, and why", whichever form the table is in: an
`ivt` object from [read_ivt(missing =
TRUE)](https://mountainmath.github.io/canivt/reference/read_ivt.md), a
Parquet path, or the Arrow connection
[`get_statcan_ivt()`](https://mountainmath.github.io/canivt/reference/get_statcan_ivt.md)
returns.

## Usage

``` r
ivt_missing(x)
```

## Arguments

- x:

  An `ivt` object, a `.parquet` path, or an Arrow dataset / dplyr query
  from
  [`get_statcan_ivt()`](https://mountainmath.github.io/canivt/reference/get_statcan_ivt.md).

## Value

For an `ivt`, the `missing` tibble (member-id coordinates); for a
Parquet source, a lazy
[`arrow::open_dataset()`](https://arrow.apache.org/docs/r/reference/open_dataset.html)
connection to the `_missing.parquet` sidecar with the same labelled
coordinates as the data. `NULL` when the table carries none – i.e. it
was decoded without `missing = TRUE`.

## Details

Every row is a cell the file marks as **not** a zero, with the reason
the file states (`symbol` / `status`), or `NA` where the page carries
only the bare absent mask. On the published table
([`read_ivt()`](https://mountainmath.github.io/canivt/reference/read_ivt.md)'s
default `complete = TRUE`) these are simply its `is.na(value)` rows, so
this is a convenience view; under `complete = FALSE` it is the only
thing separating a suppressed cell from a published zero, since neither
is stored.

## See also

[`read_ivt()`](https://mountainmath.github.io/canivt/reference/read_ivt.md),
[`ivt_tidy_missing()`](https://mountainmath.github.io/canivt/reference/ivt_tidy_missing.md),
[`ivt_write_parquet()`](https://mountainmath.github.io/canivt/reference/ivt_write_parquet.md)

## Examples

``` r
path <- system.file("extdata", "98100044.ivt", package = "canivt")
ivt_missing(read_ivt(path, missing = TRUE))
#> # A tibble: 0 × 5
#> # ℹ 5 variables: geo <int>, type <int>, collective <int>, symbol <chr>,
#> #   status <chr>
```
