# Write the table metadata (codebook + footnotes) to disk

Emits the parts of an IVT that are not the data table itself, as a set
of CSV files in `dir`: the dimension members (`dimension_members.csv`),
the geography table (`geographies.csv` – bilingual labels/names, uid,
and whatever attributes the vintage stores: aggregation level, geography
type / municipal status, data-quality flag + note, total non-response
rate), the footnotes (`footnotes.csv`), the data-quality-flag legend
(`dqf_legend.csv`, when the table carries one) and the table identity
(`table_info.csv`).

## Usage

``` r
ivt_write_metadata(x, dir = NULL)
```

## Arguments

- x:

  An `ivt` object or a metadata list from
  [`ivt_metadata()`](https://mountainmath.github.io/canivt/reference/ivt_metadata.md).

- dir:

  Output directory (created if needed). Defaults to
  `<product_id>_metadata` in the data cache
  ([ivt_cache_dir("data")](https://mountainmath.github.io/canivt/reference/ivt_cache_dir.md)).

## Value

The output directory, invisibly.

## Examples

``` r
path <- system.file("extdata", "98100044.ivt", package = "canivt")
ivt <- read_ivt(path)
out <- ivt_write_metadata(ivt, file.path(tempdir(), "98100044_metadata"))
list.files(out)
#> [1] "dimension_members.csv" "dqf_legend.csv"        "footnotes.csv"        
#> [4] "geographies.csv"       "table_info.csv"       
```
