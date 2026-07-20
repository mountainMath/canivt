# Tidy an `ivt` object into a labelled data frame

Joins the decoded cells to the codebook so each dimension column holds
its member label (and geography gains a `dguid` column), producing a
long table analogous to the StatCan CSV download.

## Usage

``` r
ivt_tidy(
  x,
  labels = TRUE,
  trim_labels = TRUE,
  dim_names = c("slug", "label"),
  language = "en",
  depth = FALSE
)
```

## Arguments

- x:

  An `ivt` object from
  [`read_ivt()`](https://mountainmath.github.io/canivt/reference/read_ivt.md).

- labels:

  If `TRUE` (default) replace member-id columns with member labels; if
  `FALSE` return the compact integer-id table (member ids).

- trim_labels:

  If `TRUE` (default) strip the hierarchy-indentation spaces from member
  labels.

- dim_names:

  How to name the data-dimension columns: `"slug"` (default) uses the
  terse structural slug (e.g. `age`), which is compact and
  language-neutral; `"label"` uses the full dimension name (e.g.
  `Age of primary household maintainer`, or its French equivalent when
  `language = "fr"`). Slug output can be labelled afterwards with
  [`label_ivt_columns()`](https://mountainmath.github.io/canivt/reference/label_ivt_columns.md).
  The choice applies to both `labels` values.

- language:

  Output language for labels and label-derived column names: `"en"`
  (default) or `"fr"`. Also accepts `"eng"`/`"fra"` and any case (it is
  lower-cased). French falls back to English wherever the file carries
  no French copy (e.g. the language-neutral `geo_uid`, or a dimension
  with no French name).

- depth:

  If `TRUE` (default `FALSE`) add a `<col>_depth` integer column after
  each data-dimension column giving that member's hierarchy depth (read
  from the label indentation, the same measure carried by
  [`ivt_members()`](https://mountainmath.github.io/canivt/reference/ivt_members.md)).
  Opt-in, so the default output – and hence the Parquet written by
  [`ivt_write_parquet()`](https://mountainmath.github.io/canivt/reference/ivt_write_parquet.md)
  – is unchanged.

## Value

A tibble.

## Examples

``` r
path <- system.file("extdata", "98100044.ivt", package = "canivt")
ivt <- read_ivt(path)
ivt_tidy(ivt)
#> # A tibble: 399 × 7
#>    geo_label geo_name geo_uid        geo_level type            collective  value
#>    <chr>     <chr>    <chr>          <chr>     <chr>           <chr>       <dbl>
#>  1 Canada    Canada   2021A000011124 Country   Total - Type o… Collectiv…  24140
#>  2 Canada    Canada   2021A000011124 Country   Total - Type o… Populatio… 657920
#>  3 Canada    Canada   2021A000011124 Country   Health care an… Collectiv…  13020
#>  4 Canada    Canada   2021A000011124 Country   Health care an… Populatio… 485320
#>  5 Canada    Canada   2021A000011124 Country   Hospitals       Collectiv…    300
#>  6 Canada    Canada   2021A000011124 Country   Hospitals       Populatio…  11125
#>  7 Canada    Canada   2021A000011124 Country   Nursing homes   Collectiv…   2435
#>  8 Canada    Canada   2021A000011124 Country   Nursing homes   Populatio… 184890
#>  9 Canada    Canada   2021A000011124 Country   Residences for… Collectiv…   2505
#> 10 Canada    Canada   2021A000011124 Country   Residences for… Populatio… 159750
#> # ℹ 389 more rows
ivt_tidy(ivt, dim_names = "label")
#> # A tibble: 399 × 7
#>    geo_label geo_name geo_uid        geo_level `Type of collective dwelling`    
#>    <chr>     <chr>    <chr>          <chr>     <chr>                            
#>  1 Canada    Canada   2021A000011124 Country   Total - Type of collective dwell…
#>  2 Canada    Canada   2021A000011124 Country   Total - Type of collective dwell…
#>  3 Canada    Canada   2021A000011124 Country   Health care and related faciliti…
#>  4 Canada    Canada   2021A000011124 Country   Health care and related faciliti…
#>  5 Canada    Canada   2021A000011124 Country   Hospitals                        
#>  6 Canada    Canada   2021A000011124 Country   Hospitals                        
#>  7 Canada    Canada   2021A000011124 Country   Nursing homes                    
#>  8 Canada    Canada   2021A000011124 Country   Nursing homes                    
#>  9 Canada    Canada   2021A000011124 Country   Residences for senior citizens   
#> 10 Canada    Canada   2021A000011124 Country   Residences for senior citizens   
#> # ℹ 389 more rows
#> # ℹ 2 more variables:
#> #   `Collective dwellings occupied by usual residents and population in collective dwellings` <chr>,
#> #   value <dbl>
```
