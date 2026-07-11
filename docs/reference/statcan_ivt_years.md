# Available census versions on the StatCan datasets index

Reads the `Temporal` selector from the StatCan census datasets index
page, i.e. the list of census versions whose IVT products can be
catalogued with
[`statcan_ivt_catalogue()`](https://mountainmath.github.io/canivt/reference/statcan_ivt_catalogue.md).

## Usage

``` r
statcan_ivt_years()
```

## Value

A tibble with one row per version: `temporal` (the URL parameter, e.g.
`"2017"` for the 2016 long-form), `census` (the human label, e.g.
`"2016 Census - Part B (long-form questionnaire)"`) and `census_year`
(the leading 4-digit year of the label as an integer). `NULL`
(invisibly, with a warning) if the index could not be reached.

## Examples

``` r
# Scrapes the StatCan datasets index. Returns NULL with a warning if offline
# (no error), so no try() is needed.
# \donttest{
statcan_ivt_years()
#> # A tibble: 11 × 3
#>    temporal census                                          census_year
#>    <chr>    <chr>                                                 <int>
#>  1 2021     2021 Census                                            2021
#>  2 2016     2016 Census – Part A (short-form questionnaire)        2016
#>  3 2017     2016 Census – Part B (long-form questionnaire)         2016
#>  4 2013     2011 NHS                                               2011
#>  5 2011     2011 Census                                            2011
#>  6 2006     2006 Census                                            2006
#>  7 2001     2001 Census                                            2001
#>  8 1996     1996 Census                                            1996
#>  9 1991     1991 Census                                            1991
#> 10 1986     1986 Census                                            1986
#> 11 1981     1981 Census                                            1981
# }
```
