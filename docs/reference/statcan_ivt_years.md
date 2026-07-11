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
(the leading 4-digit year of the label as an integer).
