# Download and read a StatCan IVT table in one step

Convenience wrapper that
[`ivt_download()`](https://mountainmath.github.io/canivt/reference/ivt_download.md)s
a table by product id and then
[`read_ivt()`](https://mountainmath.github.io/canivt/reference/read_ivt.md)s
it.

## Usage

``` r
ivt_read_table(pid, dest_dir = NULL, lang = c("en", "fr"), ...)
```

## Arguments

- pid:

  StatCan product id, e.g. `"98100241"` or `9810024101`. Any trailing
  version digits are dropped to the 8-digit table id.

- dest_dir:

  Directory to download into (created if needed). Defaults to a
  per-table folder under the IVT cache
  ([ivt_cache_dir("ivt")](https://mountainmath.github.io/canivt/reference/ivt_cache_dir.md),
  i.e. option `canivt.ivt_cache` or
  [`tempdir()`](https://rdrr.io/r/base/tempfile.html) when unset).

- lang:

  `"en"` (default) or `"fr"` endpoint.

- ...:

  Passed to
  [`ivt_download()`](https://mountainmath.github.io/canivt/reference/ivt_download.md).

## Value

An `ivt` object (see
[`read_ivt()`](https://mountainmath.github.io/canivt/reference/read_ivt.md)).

## Examples

``` r
if (FALSE) { # \dontrun{
tab <- ivt_read_table("98100241")
ivt_write_parquet(tab, "98100241.parquet")
ivt_write_metadata(tab, "98100241_metadata")
} # }
```
