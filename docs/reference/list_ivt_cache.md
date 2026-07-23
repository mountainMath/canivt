# List the canivt cache contents

Lists the raw `.ivt` inputs (in the ivt cache) and the parsed data
Parquets (in the data cache), one row per file, enriched with catalogue
metadata (matched product number, title, census year, topic) when the
file's cache key matches a product in the
[`statcan_ivt_catalogue()`](https://mountainmath.github.io/canivt/reference/statcan_ivt_catalogue.md).
The member sidecars (`_members.parquet`) and the catalogue cache itself
are infrastructure and are not listed.

## Usage

``` r
list_ivt_cache(catalogue = NULL)
```

## Arguments

- catalogue:

  A catalogue tibble (from
  [`statcan_ivt_catalogue()`](https://mountainmath.github.io/canivt/reference/statcan_ivt_catalogue.md))
  used to enrich the listing. `NULL` (default) reads the **cached**
  catalogue if one exists and skips enrichment otherwise – it never
  triggers a scrape, so this function works offline.

## Value

A tibble with one row per cached file: `kind` (`"ivt"` or `"parquet"`),
`key` (the cache key – the catalogue number for downloaded tables, the
folder/file name otherwise), `language` (`"en"`/`"fr"` for a
language-marked Parquet, `NA` for `.ivt` files and old unmarked
Parquets), `path`, `bytes`, `modified`, and the catalogue columns
`catalogue`, `title`, `census_year`, `topic` (`NA` when the key matches
no product).

## See also

[`get_statcan_ivt()`](https://mountainmath.github.io/canivt/reference/get_statcan_ivt.md),
[`statcan_ivt_catalogue()`](https://mountainmath.github.io/canivt/reference/statcan_ivt_catalogue.md)

## Examples

``` r
# Lists whatever is in the configured cache directories (empty when unset):
list_ivt_cache()
#> # A tibble: 103 × 10
#>    kind    key             language catalogue     title census_year topic  bytes
#>    <chr>   <chr>           <chr>    <chr>         <chr>       <int> <chr>  <dbl>
#>  1 ivt     0               NA       NA            NA             NA NA    1.36e8
#>  2 ivt     1003011         NA       1003011       E910…        1991 Age,… 2.67e7
#>  3 parquet 1003011         en       1003011       E910…        1991 Age,… 1.31e7
#>  4 parquet 1003011         NA       1003011       E910…        1991 Age,… 1.27e7
#>  5 ivt     94F0009XDB96078 NA       94F0009XDB96… Cens…        1996 Sour… 1.17e5
#>  6 ivt     95F0170X        NA       95F0170X      Prof…        1991 Prof… 9.26e6
#>  7 ivt     95F0200XDB96003 NA       95F0200XDB96… Occu…        1996 Occu… 2.40e7
#>  8 ivt     95F0223XDB96001 NA       95F0223XDB96… Tota…        1996 Immi… 3.26e6
#>  9 ivt     95F0250XDB96001 NA       95F0250XDB96… Priv…        1996 Sour… 7.82e5
#> 10 ivt     95f0491xcb01004 NA       SP3/NIQKF5/9… Cens…          NA NA    1.37e5
#> # ℹ 93 more rows
#> # ℹ 2 more variables: modified <dttm>, path <chr>
```
