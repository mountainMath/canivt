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
#> Sending a browser through to 'www12.statcan.gc.ca'.
#>   Trying headless Chrome first.
#> 'www12.statcan.gc.ca' is asking the escort for a check again; passing it.
#> Warning: Could not reach
#> <https://www12.statcan.gc.ca/datasets/Index-eng.cfm?Temporal=2021>. ℹ Check
#> your internet connection; the resource may also be unavailable. Caused by
#> error: ! The browser check at 'www12.statcan.gc.ca' was not passed within 30
#> seconds.
# }
```
