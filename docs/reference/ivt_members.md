# Member levels of an IVT table

Returns one row per (column, member) for every labelled **data**
dimension
[`ivt_tidy()`](https://mountainmath.github.io/canivt/reference/ivt_tidy.md)
emits, in its stored member-ordinal order. This is the level table
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
full English dimension name), `dimension_fr` (the French dimension name,
`NA` when none – used by
[`label_ivt_columns()`](https://mountainmath.github.io/canivt/reference/label_ivt_columns.md)),
`member_id` (1-based StatCan member id), `ordinal` (the codebook
member-ordinal; equals `member_id` when the file stores no ordinal
block), `label` (the stored label, untrimmed), `level` (the label as it
appears in the tidy output), `level_fr` (the French label, `NA` when the
file carries none for that column), `depth` (hierarchy depth implied by
the label indentation), `parent_id` (the `member_id` of this member's
parent in that hierarchy – the nearest preceding member at a shallower
depth, `NA` for top-level members), and `description`/`description_fr`
(the member's `_Description` prose – the indicator definition carried by
the facet / quantity dimension of the older survey tables, e.g. a total
fertility rate's "... the number of children born per 1,000 women ...",
which states the value's units; `NA` for the many dimensions/tables that
carry none).

## Details

The geography columns are **not** levelled. Geography is an identity
axis rather than a category: `geo_uid` is the language-neutral key you
join on, the member list runs to tens of thousands of entries on the
large tables, and its ordinal is a hierarchy traversal rather than an
analytic order. Per-member geography context – names, identifiers,
quality flags, and the label hierarchy as `geo_depth`/`geo_parent_id` –
lives in `metadata$geographies` instead.

## See also

[`collect_ivt()`](https://mountainmath.github.io/canivt/reference/collect_ivt.md)

## Examples

``` r
path <- system.file("extdata", "98100044.ivt", package = "canivt")
ivt <- read_ivt(path)
ivt_members(ivt)
#> # A tibble: 18 × 12
#>    column    dimension dimension_fr member_id ordinal label level level_fr depth
#>    <chr>     <chr>     <chr>            <int>   <int> <chr> <chr> <chr>    <int>
#>  1 type      Type of … Type de log…         1       1 "Tot… Tota… Total -…     0
#>  2 type      Type of … Type de log…         2       2 "  H… Heal… Établis…     1
#>  3 type      Type of … Type de log…         3       3 "   … Hosp… Hôpitaux     2
#>  4 type      Type of … Type de log…         4       4 "   … Nurs… Établis…     2
#>  5 type      Type of … Type de log…         5       5 "   … Resi… Résiden…     2
#>  6 type      Type of … Type de log…         6       6 "   … Faci… Établis…     2
#>  7 type      Type of … Type de log…         7       7 "   … Resi… Établis…     2
#>  8 type      Type of … Type de log…         8       8 "  C… Corr… Établis…     1
#>  9 type      Type of … Type de log…         9       9 "  S… Shel… Refuges      1
#> 10 type      Type of … Type de log…        10      10 "  S… Serv… Logemen…     1
#> 11 type      Type of … Type de log…        11      11 "   … Lodg… Maisons…     2
#> 12 type      Type of … Type de log…        12      12 "   … Hote… Hôtels,…     2
#> 13 type      Type of … Type de log…        13      13 "   … Othe… Autres …     2
#> 14 type      Type of … Type de log…        14      14 "  R… Reli… Établis…     1
#> 15 type      Type of … Type de log…        15      15 "  H… Hutt… Colonie…     1
#> 16 type      Type of … Type de log…        16      16 "  O… Othe… Autres …     1
#> 17 collecti… Collecti… Logements c…         1       1 "Col… Coll… Logemen…     0
#> 18 collecti… Collecti… Logements c…         2       2 "Pop… Popu… Populat…     0
#> # ℹ 3 more variables: parent_id <int>, description <chr>, description_fr <chr>
```
