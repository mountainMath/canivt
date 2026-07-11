# Catalogue of StatCan Beyond 20/20 IVT products

Scrapes the StatCan census datasets index into a tidy catalogue of every
IVT product: census year, catalogue number, release date, topic, title
and the download URLs. The full catalogue (all census versions) is
cached as a Parquet file in the data cache
([ivt_cache_dir("data")](https://mountainmath.github.io/canivt/reference/ivt_cache_dir.md))
so it is scraped only once; pass `refresh = TRUE` to rebuild it. When
the cached catalogue is a month or more old a warning (once per session)
suggests refreshing it.

## Usage

``` r
statcan_ivt_catalogue(temporal = NULL, refresh = FALSE, quiet = FALSE)
```

## Arguments

- temporal:

  Optional character/numeric vector of census versions to return (the
  `temporal` values from
  [`statcan_ivt_years()`](https://mountainmath.github.io/canivt/reference/statcan_ivt_years.md),
  e.g. `2001` or `c(2021, 2016)`). When `NULL` (default) the whole
  catalogue is returned. Filtering does not avoid building the full
  cache the first time.

- refresh:

  Re-scrape the index even if a cached catalogue exists.

- quiet:

  Suppress per-page progress messages.

## Value

A tibble with columns `census_year`, `temporal`, `catalogue`,
`archived`, `release_date`, `date`, `topic`, `title`, `pid`, `ivt_url`,
`download_url` and `http_url`. `ivt_url` is the link as published (the
`Alternative.cfm` intermediate page or a direct b2020 `.zip`);
`download_url` is the resolved direct-download URL (see
[`statcan_ivt_resolve_url()`](https://mountainmath.github.io/canivt/reference/statcan_ivt_resolve_url.md)).
`NULL` (invisibly, with a warning) if the index had to be scraped and
could not be reached.

## Examples

``` r
# Scrapes the StatCan datasets index (and caches it). Returns NULL with a
# warning if offline (no error), so no try() is needed.
# \donttest{
catl <- statcan_ivt_catalogue(temporal = 2021)
head(catl)
#> # A tibble: 6 × 12
#>   census_year temporal catalogue   archived release_date date  topic title pid  
#>         <int> <chr>    <chr>       <lgl>    <date>       <chr> <chr> <chr> <chr>
#> 1        2021 2021     98-402-X20… FALSE    2022-02-09   Febr… Popu… Popu… NA   
#> 2        2021 2021     98-402-X20… FALSE    2022-02-09   Febr… Popu… Popu… NA   
#> 3        2021 2021     98-402-X20… FALSE    2023-03-29   Marc… Popu… Popu… NA   
#> 4        2021 2021     98-402-X20… FALSE    2022-02-09   Febr… Popu… Popu… NA   
#> 5        2021 2021     98-402-X20… FALSE    2022-02-09   Febr… Popu… Popu… NA   
#> 6        2021 2021     98-402-X20… FALSE    2022-02-09   Febr… Popu… Popu… NA   
#> # ℹ 3 more variables: ivt_url <chr>, download_url <chr>, http_url <chr>
# }
```
