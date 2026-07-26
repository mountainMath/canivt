# Relabel slug data columns with their full dimension names

The Parquet written by
[`ivt_write_parquet()`](https://mountainmath.github.io/canivt/reference/ivt_write_parquet.md)
/
[`get_statcan_ivt()`](https://mountainmath.github.io/canivt/reference/get_statcan_ivt.md)
names its data-dimension columns by their compact structural slug
(`age`, `tenure`, ...). This renames those columns to the full dimension
label – English or French – on an Arrow dataset / dplyr-on-Arrow query
(lazily, no data read) or a collected data frame. Geography columns
(`geo_name`, `geo_uid`, ...) are left as is; a column whose slug is not
found is skipped.

## Usage

``` r
label_ivt_columns(x, members = NULL, language = NULL)
```

## Arguments

- x:

  An Arrow dataset, a dplyr-on-Arrow query, or a data frame.

- members:

  A level table from
  [`ivt_members()`](https://mountainmath.github.io/canivt/reference/ivt_members.md);
  when `NULL` it is located from `x` (attached `members` attribute or
  the `_members.parquet` sidecar).

- language:

  `"en"` or `"fr"`; `NULL` (default) auto-detects from the file name
  (see
  [`ivt_parquet_language()`](https://mountainmath.github.io/canivt/reference/ivt_parquet_language.md)).

## Value

`x` with its data-dimension columns renamed (an Arrow query when `x` is
an Arrow object, else a data frame).

## Details

The slug -\> label map comes from the `<name>_members.parquet` sidecar
(or an explicit `members` table, e.g. from
[`ivt_members()`](https://mountainmath.github.io/canivt/reference/ivt_members.md)).
The language is taken from the file name marker via
[`ivt_parquet_language()`](https://mountainmath.github.io/canivt/reference/ivt_parquet_language.md)
unless given, so the labels match the language the Parquet was written
in.

It can be called either side of
[`collect_ivt()`](https://mountainmath.github.io/canivt/reference/collect_ivt.md):
before, on the connection (nothing is read until the collect), or after,
on the collected data frame – which carries the member table it used as
an attribute. Either order gives the same labelled, fully-levelled
result, and `collect_ivt(dim_names = "label")` is the one-call shorthand
for it.

## See also

[`collect_ivt()`](https://mountainmath.github.io/canivt/reference/collect_ivt.md),
[`ivt_parquet_language()`](https://mountainmath.github.io/canivt/reference/ivt_parquet_language.md)

## Examples

``` r
path <- system.file("extdata", "98100044.ivt", package = "canivt")
ivt <- read_ivt(path)
if (requireNamespace("dplyr", quietly = TRUE)) {
  df <- ivt_tidy(ivt, labels = FALSE)          # slug-named columns
  labelled <- label_ivt_columns(df, members = ivt_members(ivt))
  names(labelled)
}
#> [1] "geo"                                                                                    
#> [2] "Type of collective dwelling"                                                            
#> [3] "Collective dwellings occupied by usual residents and population in collective dwellings"
#> [4] "value"                                                                                  
```
