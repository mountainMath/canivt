# Download a StatCan IVT by its direct-download URL

Downloads a `.ivt` (or its containing `.zip`) from a resolved
[`statcan_ivt_resolve_url()`](https://mountainmath.github.io/canivt/reference/statcan_ivt_resolve_url.md)
URL into the ivt cache and returns the local `.ivt` path. The payload is
sniffed: a `.zip` is unzipped, a raw IVT is kept as-is.

## Usage

``` r
statcan_ivt_download(
  download_url,
  key = NULL,
  dest_dir = NULL,
  overwrite = FALSE,
  quiet = FALSE
)
```

## Arguments

- download_url:

  A direct-download URL (a b2020 `.zip` or a `Download.cfm?PID=`
  endpoint), **or** a one-row
  [`statcan_ivt_catalogue()`](https://mountainmath.github.io/canivt/reference/statcan_ivt_catalogue.md)
  tibble (its `download_url` and, by default, its `catalogue` number as
  the cache key are used).

- key:

  Cache key used to name the per-table folder under the ivt cache.
  Optional when `download_url` is a catalogue row (defaults to the row's
  catalogue number).

- dest_dir:

  Directory the `.ivt` is written to. Defaults to a per-table folder
  under the ivt cache
  ([ivt_cache_dir("ivt")](https://mountainmath.github.io/canivt/reference/ivt_cache_dir.md));
  [`get_statcan_ivt()`](https://mountainmath.github.io/canivt/reference/get_statcan_ivt.md)
  passes a temporary folder when `keep_ivt = FALSE`.

- overwrite:

  Re-download even if a `.ivt` already exists.

- quiet:

  Suppress the download message.

## Value

Path to the local `.ivt` file, or `NULL` (invisibly, with a warning) if
the endpoint could not be reached.

## Examples

``` r
# Downloads from Statistics Canada. Returns NULL with a warning if offline
# (no error), so no try() is needed.
# \donttest{
url <- statcan_ivt_resolve_url("Alternative.cfm?PID=55701&EXT=IVT")
path <- statcan_ivt_download(url, key = "97-570-X1981004", dest_dir = tempdir())
# }
```
