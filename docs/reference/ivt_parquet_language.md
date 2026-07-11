# Detect the language of an IVT Parquet

Reads the language marker (`_en` / `_fr` before `.parquet`) that
[`ivt_write_parquet()`](https://mountainmath.github.io/canivt/reference/ivt_write_parquet.md)
/
[`get_statcan_ivt()`](https://mountainmath.github.io/canivt/reference/get_statcan_ivt.md)
put in the file name, so
[`collect_ivt()`](https://mountainmath.github.io/canivt/reference/collect_ivt.md)
and
[`label_ivt_columns()`](https://mountainmath.github.io/canivt/reference/label_ivt_columns.md)
can pick the matching language without being told. Falls back to `"en"`
when there is no marker.

## Usage

``` r
ivt_parquet_language(x)
```

## Arguments

- x:

  A `.parquet` path, an Arrow dataset, or a dplyr-on-Arrow query (the
  path is taken from the `path` attribute / source file list).

## Value

`"en"` or `"fr"`.
