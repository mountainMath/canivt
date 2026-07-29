# Write an IVT table to CSV

The output is **gzipped by default**. The published table is one row per
grid coordinate with every dimension's label repeated on each of them,
which is about as compressible as tabular data gets – an order of
magnitude off the plain text, for a format every reader (including
`readr`, `arrow`, `pandas` and `duckdb`) opens directly. Pass
`compress = FALSE` for plain `.csv`.

## Usage

``` r
ivt_write_csv(
  x,
  path = NULL,
  labels = TRUE,
  missing = TRUE,
  dim_names = c("slug", "label"),
  language = "en",
  compress = TRUE,
  chunk_cells = getOption("canivt.chunk_cells", 5e+06),
  ...
)
```

## Arguments

- x:

  An `ivt` object from
  [`read_ivt()`](https://mountainmath.github.io/canivt/reference/read_ivt.md),
  **or the path to an `.ivt` file** – then the table is decoded and
  written a chunk at a time and the completed grid is never held whole,
  so a table far larger than memory converts on a small machine. The
  written file is the same one the in-memory path produces. See
  `chunk_cells`.

- path:

  Output `.csv.gz` path. Defaults to `<product_id>.csv.gz` in the data
  cache
  ([ivt_cache_dir("data")](https://mountainmath.github.io/canivt/reference/ivt_cache_dir.md)).
  As with
  [`ivt_write_parquet()`](https://mountainmath.github.io/canivt/reference/ivt_write_parquet.md),
  passing the path of an `.ivt` file as `x` converts it a chunk at a
  time rather than materialising the whole table.

- labels:

  Passed to
  [`ivt_tidy()`](https://mountainmath.github.io/canivt/reference/ivt_tidy.md):
  write labelled columns (`TRUE`, default) or the compact integer-id
  table (`FALSE`).

- missing:

  Also write the cell-status table
  ([`ivt_tidy_missing()`](https://mountainmath.github.io/canivt/reference/ivt_tidy_missing.md))
  to a `<name>_missing.csv.gz` next to `path` (`TRUE`, default), when
  `x` carries one (i.e. was read with `read_ivt(missing = TRUE)`).
  Silently skipped otherwise.

- dim_names:

  How to name the data-dimension columns (passed to
  [`ivt_tidy()`](https://mountainmath.github.io/canivt/reference/ivt_tidy.md)
  and the member sidecar): `"slug"` (default, the terse structural slug)
  or `"label"` (the full dimension name). Slug columns can be labelled
  on read with
  [`label_ivt_columns()`](https://mountainmath.github.io/canivt/reference/label_ivt_columns.md).

- language:

  Output language for labels and label-derived column names (passed to
  [`ivt_tidy()`](https://mountainmath.github.io/canivt/reference/ivt_tidy.md)):
  `"en"` (default) or `"fr"`. The member sidecar carries both languages
  regardless.

- compress:

  Gzip the output (`TRUE`, default). The extension always tells the
  truth about the file: `.gz` is appended to a `path` that lacks it, and
  a `path` that already ends in `.gz` is compressed whatever `compress`
  says. The written path – which may not be the one passed – is what is
  returned.

- chunk_cells:

  Only when `x` is a file path: how many grid rows to decode, write and
  drop at a time (default `getOption("canivt.chunk_cells", 5e6)`).
  Chunks are cut along the outermost paged dimension – usually geography
  – which is the axis the file itself pages on, so a chunk is a
  contiguous run of output rows and no page is read twice. A table whose
  layout pages on nothing but the straddle window cannot be sliced and
  is held whole, subject to the usual `canivt.max_cells` guard.

- ...:

  Passed to the CSV writer
  ([`readr::write_csv()`](https://readr.tidyverse.org/reference/write_delim.html)
  if available, else
  [`utils::write.table()`](https://rdrr.io/r/utils/write.table.html)).

## Value

The path written, invisibly.

## Examples

``` r
path <- system.file("extdata", "98100044.ivt", package = "canivt")
ivt <- read_ivt(path)
out <- ivt_write_csv(ivt, file.path(tempdir(), "98100044.csv"))
basename(out)                       # .gz appended
#> [1] "98100044.csv"
head(readLines(out), 3)             # ... and read back transparently
#> [1] "geo_label,geo_name,geo_uid,geo_level,type,collective,value,symbol,status"                                                             
#> [2] "Canada,Canada,2021A000011124,Country,Total - Type of collective dwelling,Collective dwellings occupied by usual residents,24140,NA,NA"
#> [3] "Canada,Canada,2021A000011124,Country,Total - Type of collective dwelling,Population in collective dwellings,657920,NA,NA"             
# the same file, decoded and written a chunk at a time, uncompressed
ivt_write_csv(path, file.path(tempdir(), "streamed.csv"), compress = FALSE)
#> Error in readr::write_csv(df, p, ...): unused argument (compress = FALSE)
```
