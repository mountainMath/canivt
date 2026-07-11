# Download a Borealis IVT file into the ivt cache

Downloads one Borealis `.ivt` (identified by a one-row
[`borealis_ivt_catalogue()`](https://mountainmath.github.io/canivt/reference/borealis_ivt_catalogue.md)
slice, or by a bare numeric `file_id`) from the Dataverse access API
into the ivt cache and returns the local `.ivt` path. Requires the
Borealis API key (`BOREALIS_DATAVERSE_KEY`).

## Usage

``` r
borealis_ivt_download(
  x,
  key = NULL,
  dest_dir = NULL,
  overwrite = FALSE,
  quiet = FALSE
)
```

## Arguments

- x:

  A one-row tibble from
  [`borealis_ivt_catalogue()`](https://mountainmath.github.io/canivt/reference/borealis_ivt_catalogue.md),
  or a Borealis `file_id` (character/numeric).

- key:

  Cache key naming the per-table folder under the ivt cache. Defaults to
  the catalogue row's `key` (or the `file_id` when `x` is a bare id).

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

Path to the local `.ivt` file.

## See also

[`borealis_ivt_catalogue()`](https://mountainmath.github.io/canivt/reference/borealis_ivt_catalogue.md),
[`get_statcan_ivt()`](https://mountainmath.github.io/canivt/reference/get_statcan_ivt.md)

## Examples

``` r
# Requires a Borealis API key (BOREALIS_DATAVERSE_KEY) and network access:
if (FALSE) { # \dontrun{
hits <- borealis_ivt_catalogue()
path <- borealis_ivt_download(hits[1, ], dest_dir = tempdir())
} # }
```
