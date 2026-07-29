# Write an IVT table to Parquet

Write an IVT table to Parquet

## Usage

``` r
ivt_write_parquet(
  x,
  path = NULL,
  labels = TRUE,
  members = TRUE,
  missing = TRUE,
  dim_names = c("slug", "label"),
  language = "en",
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

  Output `.parquet` path. Defaults to `<product_id>.parquet` in the data
  cache
  ([ivt_cache_dir("data")](https://mountainmath.github.io/canivt/reference/ivt_cache_dir.md),
  i.e. option `canivt.data_cache` or
  [`tempdir()`](https://rdrr.io/r/base/tempfile.html) when unset).

- labels:

  Passed to
  [`ivt_tidy()`](https://mountainmath.github.io/canivt/reference/ivt_tidy.md):
  write labelled columns (`TRUE`, default) or the compact integer-id
  table (`FALSE`).

- members:

  Also write the member-level table
  ([`ivt_members()`](https://mountainmath.github.io/canivt/reference/ivt_members.md))
  as a `<name>_members.parquet` sidecar next to `path` (`TRUE`,
  default), so
  [`collect_ivt()`](https://mountainmath.github.io/canivt/reference/collect_ivt.md)
  can convert dimension columns to full-level factors.

- missing:

  Also write the cell-status table
  ([`ivt_tidy_missing()`](https://mountainmath.github.io/canivt/reference/ivt_tidy_missing.md))
  as a `<name>_missing.parquet` sidecar next to `path` (`TRUE`,
  default), when `x` carries one – i.e. when it was read with
  `read_ivt(missing = TRUE)`. The data table holds only the cells that
  have a value; this sidecar is what says of the rest which are genuine
  zeros (absent from both) and which are missing, and why. Its
  coordinate columns are labelled exactly like the data table's, so the
  two join. Silently skipped when `x$missing` is `NULL`.

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

- chunk_cells:

  Only when `x` is a file path: how many grid rows to decode, write and
  drop at a time (default `getOption("canivt.chunk_cells", 5e6)`).
  Chunks are cut along the outermost paged dimension – usually geography
  – which is the axis the file itself pages on, so a chunk is a
  contiguous run of output rows and no page is read twice. A table whose
  layout pages on nothing but the straddle window cannot be sliced and
  is held whole, subject to the usual `canivt.max_cells` guard.

- ...:

  Passed to
  [`arrow::write_parquet()`](https://arrow.apache.org/docs/r/reference/write_parquet.html)
  (or, on the streaming path, to
  [arrow::ParquetFileWriter](https://arrow.apache.org/docs/r/reference/ParquetFileWriter.html)`$create()`).

## Value

`path`, invisibly.

## Examples

``` r
path <- system.file("extdata", "98100044.ivt", package = "canivt")
ivt <- read_ivt(path)
if (requireNamespace("arrow", quietly = TRUE)) {
  out <- ivt_write_parquet(ivt, file.path(tempdir(), "98100044.parquet"))
  file.exists(out)
  # the same file, without holding the completed table in memory
  ivt_write_parquet(path, file.path(tempdir(), "streamed.parquet"))
}
#> Error in ivt_tidy(x, labels = labels, dim_names = dim_names, language = language): inherits(x, "ivt") is not TRUE
```
