# List the canivt cache contents

Lists the raw `.ivt` inputs (in the ivt cache) and the parsed data
Parquets (in the data cache), one row per file, enriched with catalogue
metadata (matched product number, title, census year, topic) when the
file's cache key matches a product in the
[`statcan_ivt_catalogue()`](https://mountainmath.github.io/canivt/reference/statcan_ivt_catalogue.md).
The member sidecars (`_members.parquet`), the cell-status sidecars
(`_missing.parquet`) and the catalogue cache itself are infrastructure
and are not listed.

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
#> # A tibble: 216 × 10
#>    kind    key               language catalogue   title census_year topic  bytes
#>    <chr>   <chr>             <chr>    <chr>       <chr>       <int> <chr>  <dbl>
#>  1 ivt     1003011           NA       1003011     E910…        1991 Age,… 2.67e7
#>  2 parquet 1003011           en       1003011     E910…        1991 Age,… 1.22e7
#>  3 parquet 1003011           NA       1003011     E910…        1991 Age,… 1.27e7
#>  4 ivt     1004521           NA       1004521     N910…        1991 Labo… 7.64e6
#>  5 ivt     1006454           NA       1006454     N910…        1991 Labo… 8.36e7
#>  6 ivt     93-337-X          NA       93-337-X    Prof…        1991 Prof… 2.45e5
#>  7 ivt     93-338-X          NA       93-338-X    Prof…        1991 Prof… 7.15e5
#>  8 ivt     94-581-XCB2006007 NA       94-581-XCB… Prof…        2006 Inco… 4.38e6
#>  9 parquet 94-581-XCB2006007 en       94-581-XCB… Prof…        2006 Inco… 1.76e6
#> 10 ivt     94F0009XDB96078   NA       94F0009XDB… Cens…        1996 Sour… 1.17e5
#> # ℹ 206 more rows
#> # ℹ 2 more variables: modified <dttm>, path <chr>
```
