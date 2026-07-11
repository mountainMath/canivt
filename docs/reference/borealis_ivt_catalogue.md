# Catalogue of Borealis Dataverse Beyond 20/20 IVT products

Searches the [Borealis Dataverse](https://borealisdata.ca) for every
deposited `.ivt` file and returns a tidy catalogue. Borealis hosts
custom StatCan tabulations that complement the official
[`statcan_ivt_catalogue()`](https://mountainmath.github.io/canivt/reference/statcan_ivt_catalogue.md);
the two are used together by
[`get_statcan_ivt()`](https://mountainmath.github.io/canivt/reference/get_statcan_ivt.md),
which resolves a table against StatCan first and falls back to Borealis.

## Usage

``` r
borealis_ivt_catalogue(refresh = FALSE, quiet = FALSE)
```

## Arguments

- refresh:

  Re-run the live search even if a cached catalogue exists.

- quiet:

  Suppress per-batch progress messages.

## Value

A tibble with one row per `.ivt` file: `key` (the canonical
`<doi-token>/<file-stem>` address), `file` (the deposited filename),
`file_stem`, `file_id` (the numeric Borealis datafile id – always
unique), `dataset_doi`, `dataset_name`, `download_url`, `size_in_bytes`,
`md5`, `published_at` and `file_type`.

## Details

The search is slow (~90 s, thousands of files) so the full catalogue is
cached as a Parquet file in the data cache
([ivt_cache_dir("data")](https://mountainmath.github.io/canivt/reference/ivt_cache_dir.md));
pass `refresh = TRUE` to rebuild it. Reading the cache needs neither the
`dataverse` package nor an API key – only a live search does.

A **Borealis API key** is required to run the search. Get one from your
Borealis account
(<https://borealisdata.ca/dataverseuser.xhtml?selectTab=apiTokenTab>)
and set it as the environment variable `BOREALIS_DATAVERSE_KEY` (e.g. in
`.Renviron`).

## See also

[`statcan_ivt_catalogue()`](https://mountainmath.github.io/canivt/reference/statcan_ivt_catalogue.md),
[`get_statcan_ivt()`](https://mountainmath.github.io/canivt/reference/get_statcan_ivt.md),
[`borealis_ivt_download()`](https://mountainmath.github.io/canivt/reference/borealis_ivt_download.md)

## Examples

``` r
# Requires a Borealis API key (BOREALIS_DATAVERSE_KEY) and network access:
if (FALSE) { # \dontrun{
catl <- borealis_ivt_catalogue()
head(catl)
} # }
```
