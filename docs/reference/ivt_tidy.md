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
  depth = FALSE,
  missing = FALSE
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

- missing:

  If `TRUE` (default `FALSE`) append the table's **missing** cells – the
  ones the file marks as not available rather than zero – as rows with
  `value = NA`, and add `symbol` and `status` columns giving the reason
  the file states (`NA` on every cell that has a value, and on a missing
  cell whose page carries only the bare absent mask). Requires
  `read_ivt(path, missing = TRUE)`. This is the form to use when the
  result will be completed to a full grid, since an absent row is
  otherwise indistinguishable from a published zero;
  [`ivt_tidy_missing()`](https://mountainmath.github.io/canivt/reference/ivt_tidy_missing.md)
  returns the same cells on their own, which is what
  [`ivt_write_parquet()`](https://mountainmath.github.io/canivt/reference/ivt_write_parquet.md)
  writes as a sidecar rather than doubling the exported table.

## Value

A tibble.

## Examples

``` r
path <- system.file("extdata", "98100044.ivt", package = "canivt")
ivt <- read_ivt(path)
ivt_tidy(ivt)
#> # A tibble: 448 × 9
#>    geo_label geo_name geo_uid    geo_level type  collective  value symbol status
#>    <chr>     <chr>    <chr>      <chr>     <chr> <chr>       <dbl> <fct>  <fct> 
#>  1 Canada    Canada   2021A0000… Country   Tota… Collectiv…  24140 NA     NA    
#>  2 Canada    Canada   2021A0000… Country   Tota… Populatio… 657920 NA     NA    
#>  3 Canada    Canada   2021A0000… Country   Heal… Collectiv…  13020 NA     NA    
#>  4 Canada    Canada   2021A0000… Country   Heal… Populatio… 485320 NA     NA    
#>  5 Canada    Canada   2021A0000… Country   Hosp… Collectiv…    300 NA     NA    
#>  6 Canada    Canada   2021A0000… Country   Hosp… Populatio…  11125 NA     NA    
#>  7 Canada    Canada   2021A0000… Country   Nurs… Collectiv…   2435 NA     NA    
#>  8 Canada    Canada   2021A0000… Country   Nurs… Populatio… 184890 NA     NA    
#>  9 Canada    Canada   2021A0000… Country   Resi… Collectiv…   2505 NA     NA    
#> 10 Canada    Canada   2021A0000… Country   Resi… Populatio… 159750 NA     NA    
#> # ℹ 438 more rows
ivt_tidy(ivt, dim_names = "label")
#> # A tibble: 448 × 9
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
#> # ℹ 438 more rows
#> # ℹ 4 more variables:
#> #   `Collective dwellings occupied by usual residents and population in collective dwellings` <chr>,
#> #   value <dbl>, symbol <fct>, status <fct>
```
