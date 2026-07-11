# Member levels of an IVT table

Returns one row per (column, member) for every labelled column that
[`ivt_tidy()`](https://mountainmath.github.io/canivt/reference/ivt_tidy.md)
emits: each data dimension (with its stored member-ordinal order) and
the geography columns. This is the level table
[`collect_ivt()`](https://mountainmath.github.io/canivt/reference/collect_ivt.md)
uses to convert dimension columns into factors whose levels cover
**all** members – including members filtered out of the data – and it is
written next to the cached Parquet by
[`ivt_write_parquet()`](https://mountainmath.github.io/canivt/reference/ivt_write_parquet.md)
/
[`get_statcan_ivt()`](https://mountainmath.github.io/canivt/reference/get_statcan_ivt.md)
(as `<name>_members.parquet`).

## Usage

``` r
ivt_members(
  x,
  trim_labels = TRUE,
  dim_names = c("slug", "label"),
  language = "en"
)
```

## Arguments

- x:

  An `ivt` object from
  [`read_ivt()`](https://mountainmath.github.io/canivt/reference/read_ivt.md).

- trim_labels:

  Trim the hierarchy-indentation whitespace from `level` the same way
  [`ivt_tidy()`](https://mountainmath.github.io/canivt/reference/ivt_tidy.md)
  does by default (`TRUE`).

- dim_names:

  How the data-dimension `column` names are formed, matching
  [`ivt_tidy()`](https://mountainmath.github.io/canivt/reference/ivt_tidy.md):
  `"slug"` (default, the terse structural slug) or `"label"` (the full
  dimension name). Must match the tidy output the levels will be joined
  to.

- language:

  Language for the `column` names (label mode), matching
  [`ivt_tidy()`](https://mountainmath.github.io/canivt/reference/ivt_tidy.md):
  `"en"` (default) or `"fr"`. The table always carries both the English
  `level` and the French `level_fr`, so a single sidecar serves both
  languages; only the label-derived `column` names follow `language`.

## Value

A tibble with columns `column` (the tidy column name), `dimension` (the
full English dimension name; `"Geography"` for the geography columns),
`dimension_fr` (the French dimension name, `NA` when none – used by
[`label_ivt_columns()`](https://mountainmath.github.io/canivt/reference/label_ivt_columns.md)),
`member_id` (1-based StatCan member id), `ordinal` (the codebook
member-ordinal; equals `member_id` when the file stores no ordinal
block), `label` (the stored label, untrimmed), `level` (the label as it
appears in the tidy output), `level_fr` (the French label, `NA` when the
file carries none for that column), `depth` (hierarchy depth implied by
the label indentation) and `parent_id` (the `member_id` of this member's
parent in that hierarchy – the nearest preceding member at a shallower
depth, `NA` for top-level members).

## See also

[`collect_ivt()`](https://mountainmath.github.io/canivt/reference/collect_ivt.md)

## Examples

``` r
path <- system.file("extdata", "98100044.ivt", package = "canivt")
ivt <- read_ivt(path)
ivt_members(ivt)
#> # A tibble: 74 × 10
#>    column dimension    dimension_fr member_id ordinal label level level_fr depth
#>    <chr>  <chr>        <chr>            <int>   <int> <chr> <chr> <chr>    <int>
#>  1 type   Type of col… Type de log…         1       1 "Tot… Tota… Total -…     0
#>  2 type   Type of col… Type de log…         2       2 "  H… Heal… Établis…     1
#>  3 type   Type of col… Type de log…         3       3 "   … Hosp… Hôpitaux     2
#>  4 type   Type of col… Type de log…         4       4 "   … Nurs… Établis…     2
#>  5 type   Type of col… Type de log…         5       5 "   … Resi… Résiden…     2
#>  6 type   Type of col… Type de log…         6       6 "   … Faci… Établis…     2
#>  7 type   Type of col… Type de log…         7       7 "   … Resi… Établis…     2
#>  8 type   Type of col… Type de log…         8       8 "  C… Corr… Établis…     1
#>  9 type   Type of col… Type de log…         9       9 "  S… Shel… Refuges      1
#> 10 type   Type of col… Type de log…        10      10 "  S… Serv… Logemen…     1
#> # ℹ 64 more rows
#> # ℹ 1 more variable: parent_id <int>
```
