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
