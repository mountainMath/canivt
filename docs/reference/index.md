# Package index

## Finding and downloading tables

Catalogues of the published IVT products and the downloads into the
`ivt` cache. The `www12.statcan.gc.ca` host sits behind a browser check;
install `safeconduct` to pass it (see the README).

### Statistics Canada

- [`statcan_ivt_years()`](https://mountainmath.github.io/canivt/reference/statcan_ivt_years.md)
  : Available census versions on the StatCan datasets index
- [`statcan_ivt_catalogue()`](https://mountainmath.github.io/canivt/reference/statcan_ivt_catalogue.md)
  : Catalogue of StatCan Beyond 20/20 IVT products
- [`statcan_ivt_resolve_url()`](https://mountainmath.github.io/canivt/reference/statcan_ivt_resolve_url.md)
  : Resolve a published IVT link to its direct-download URL
- [`statcan_ivt_download()`](https://mountainmath.github.io/canivt/reference/statcan_ivt_download.md)
  : Download a StatCan IVT by its direct-download URL
- [`ivt_download()`](https://mountainmath.github.io/canivt/reference/ivt_download.md)
  : Download a Beyond 20/20 IVT table from Statistics Canada

### Borealis Dataverse

- [`borealis_ivt_catalogue()`](https://mountainmath.github.io/canivt/reference/borealis_ivt_catalogue.md)
  : Catalogue of Borealis Dataverse Beyond 20/20 IVT products
- [`borealis_ivt_download()`](https://mountainmath.github.io/canivt/reference/borealis_ivt_download.md)
  : Download a Borealis IVT file into the ivt cache

## Reading a table

Decode an `.ivt` file into the published table, its codebook and
footnotes, and label it.

- [`read_ivt()`](https://mountainmath.github.io/canivt/reference/read_ivt.md)
  : Read a Beyond 20/20 IVT file

- [`ivt_read_table()`](https://mountainmath.github.io/canivt/reference/ivt_read_table.md)
  : Download and read a StatCan IVT table in one step

- [`ivt_metadata()`](https://mountainmath.github.io/canivt/reference/ivt_metadata.md)
  : Read only the metadata of an IVT file (no value decoding)

- [`ivt_tidy()`](https://mountainmath.github.io/canivt/reference/ivt_tidy.md)
  :

  Tidy an `ivt` object into a labelled data frame

- [`label_ivt_columns()`](https://mountainmath.github.io/canivt/reference/label_ivt_columns.md)
  : Relabel slug data columns with their full dimension names

- [`ivt_members()`](https://mountainmath.github.io/canivt/reference/ivt_members.md)
  : Member levels of an IVT table

- [`collect_ivt()`](https://mountainmath.github.io/canivt/reference/collect_ivt.md)
  : Collect IVT data with dimension columns as factors

## Flagged cells

The cell-status block, opt-in with `read_ivt(missing = TRUE)`. Which
absent cells are suppressed, not applicable, and so on, per the file’s
own legend.

- [`ivt_missing()`](https://mountainmath.github.io/canivt/reference/ivt_missing.md)
  : Get the cell-status (missing-cell) table
- [`ivt_tidy_missing()`](https://mountainmath.github.io/canivt/reference/ivt_tidy_missing.md)
  : Tidy the cell-status (missing-cell) table

## Writing to Parquet and CSV

- [`ivt_write_parquet()`](https://mountainmath.github.io/canivt/reference/ivt_write_parquet.md)
  : Write an IVT table to Parquet
- [`ivt_write_csv()`](https://mountainmath.github.io/canivt/reference/ivt_write_csv.md)
  : Write an IVT table to CSV
- [`ivt_write_metadata()`](https://mountainmath.github.io/canivt/reference/ivt_write_metadata.md)
  : Write the table metadata (codebook + footnotes) to disk
- [`ivt_parquet_language()`](https://mountainmath.github.io/canivt/reference/ivt_parquet_language.md)
  : Detect the language of an IVT Parquet

## The Parquet cache

One step from product id to an Arrow connection, and the cache behind
it.

- [`get_statcan_ivt()`](https://mountainmath.github.io/canivt/reference/get_statcan_ivt.md)
  : Get a StatCan IVT table as a Parquet connection
- [`ivt_cache_dir()`](https://mountainmath.github.io/canivt/reference/ivt_cache_dir.md)
  : canivt cache directories
- [`list_ivt_cache()`](https://mountainmath.github.io/canivt/reference/list_ivt_cache.md)
  : List the canivt cache contents
- [`prune_ivt_cache()`](https://mountainmath.github.io/canivt/reference/prune_ivt_cache.md)
  : Prune files from the canivt cache
