# Download a Beyond 20/20 IVT table from Statistics Canada

Fetches and unzips the `.ivt` for a StatCan data table from the public
Beyond 20/20 endpoint
(`https://www150.statcan.gc.ca/n1/<lang>/tbl/b2020/<pid>.zip`).

## Usage

``` r
ivt_download(
  pid,
  dest_dir = NULL,
  lang = c("en", "fr"),
  overwrite = FALSE,
  quiet = FALSE
)
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

- overwrite:

  Re-download even if the `.ivt` already exists. Default `FALSE`.

- quiet:

  Suppress the download progress bar. Default `FALSE`.

## Value

Path to the downloaded `.ivt` file, or `NULL` (invisibly, with a
warning) if the endpoint could not be reached.

## Examples

``` r
# Downloads from Statistics Canada. Returns NULL with a warning if offline
# (no error), so no try() is needed.
# \donttest{
path <- ivt_download("98100241", dest_dir = tempdir())
#> Downloading <https://www150.statcan.gc.ca/n1/en/tbl/b2020/98100241.zip>
if (!is.null(path)) ivt <- read_ivt(path)
# }
```
