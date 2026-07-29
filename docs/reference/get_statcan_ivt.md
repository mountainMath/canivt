# Get a StatCan IVT table as a Parquet connection

One-stop accessor: given a table id, this resolves the product (the
[`statcan_ivt_catalogue()`](https://mountainmath.github.io/canivt/reference/statcan_ivt_catalogue.md)
first, then the
[`borealis_ivt_catalogue()`](https://mountainmath.github.io/canivt/reference/borealis_ivt_catalogue.md)
of custom tabulations), downloads its `.ivt` (cached in the ivt cache),
decodes it with
[`read_ivt()`](https://mountainmath.github.io/canivt/reference/read_ivt.md),
writes the tidy table to Parquet (cached in the data cache) and returns
an Arrow connection to that Parquet so the data can be queried lazily
(e.g. with `dplyr`) without loading it all into memory.

## Usage

``` r
get_statcan_ivt(
  catalogue,
  geo_attributes = FALSE,
  labels = TRUE,
  missing = FALSE,
  dim_names = c("slug", "label"),
  language = "en",
  keep_ivt = FALSE,
  refresh = FALSE,
  quiet = FALSE,
  complete = TRUE
)
```

## Arguments

- catalogue:

  A StatCan catalogue number (e.g. `"98-10-0241-01"`,
  `"95F0436XCB2001003"`), a Borealis id (a filename like `"CD1T29M3"`,
  its DOI-qualified key like `"SP3/6DGOTF/CD1T29M3"`, or a numeric
  `file_id`), or a custom identifier matching a local `.ivt` in the ivt
  cache. Matching is case- and punctuation-insensitive. A bare Borealis
  filename that occurs in several datasets is ambiguous and aborts with
  the disambiguating keys. **A one-row tibble from
  [`statcan_ivt_catalogue()`](https://mountainmath.github.io/canivt/reference/statcan_ivt_catalogue.md)
  or
  [`borealis_ivt_catalogue()`](https://mountainmath.github.io/canivt/reference/borealis_ivt_catalogue.md)**
  may be passed instead of an id, routing straight to that row's source
  with no catalogue lookup. A **named** length-one vector/list
  (`c(key = "url-or-path")`) is a manual import: its name is the cache
  key and its value a URL or local file path to a zipped or raw `.ivt`.

- geo_attributes:

  Passed to
  [`read_ivt()`](https://mountainmath.github.io/canivt/reference/read_ivt.md):
  decode the full family-2 geography attribute table (slower) so
  geographies can be labelled by name.

- labels:

  Passed to
  [`ivt_write_parquet()`](https://mountainmath.github.io/canivt/reference/ivt_write_parquet.md):
  write labelled columns (`TRUE`, default) or the compact integer-id
  table.

- missing:

  Passed to
  [`read_ivt()`](https://mountainmath.github.io/canivt/reference/read_ivt.md):
  additionally cache the flagged cells on their own as a
  `<key>_<lang>_missing.parquet` sidecar. Off by default because the
  cached table already carries them (see `complete`); the sidecar is
  only worth writing when the same cells are wanted in isolation. A
  cached Parquet with no sidecar is re-decoded when this is `TRUE`.

- dim_names:

  Passed to
  [`ivt_write_parquet()`](https://mountainmath.github.io/canivt/reference/ivt_write_parquet.md):
  name the data-dimension columns by the full dimension label
  (`"label"`, default) or the terse structural slug (`"slug"`).

- language:

  Passed to
  [`ivt_write_parquet()`](https://mountainmath.github.io/canivt/reference/ivt_write_parquet.md):
  output labels and label-derived column names in English (`"en"`,
  default) or French (`"fr"`).

- keep_ivt:

  Persist the downloaded/imported raw `.ivt` in the ivt cache
  ([ivt_cache_dir("ivt")](https://mountainmath.github.io/canivt/reference/ivt_cache_dir.md)).
  The default `FALSE` decodes the `.ivt` from a temporary copy and then
  discards it, keeping only the parsed Parquet (re-fetched if the
  Parquet is later rebuilt). A raw `.ivt` already persisted in the ivt
  cache is reused regardless of this flag.

- refresh:

  Re-download and re-parse even if cached outputs exist.

- quiet:

  Suppress progress messages.

- complete:

  Passed to
  [`read_ivt()`](https://mountainmath.github.io/canivt/reference/read_ivt.md):
  cache the **published table** – every grid coordinate, published zeros
  included, flagged cells carrying `symbol`/`status` and a `NA` value
  (`TRUE`, default). A Parquet cached in the older store-only form is
  re-decoded rather than answering with fewer rows.

## Value

An
[`arrow::open_dataset()`](https://arrow.apache.org/docs/r/reference/open_dataset.html)
connection to the Parquet file. The Parquet path is attached as
`attr(., "path")`; the resolved catalogue row (if any) as
`attr(., "catalogue_row")`; the member-level table
([`ivt_members()`](https://mountainmath.github.io/canivt/reference/ivt_members.md),
read from the `_members.parquet` sidecar when present) as
`attr(., "members")` –
[`collect_ivt()`](https://mountainmath.github.io/canivt/reference/collect_ivt.md)
uses it to convert dimension columns into full-level factors – and, when
`missing = TRUE`, a lazy connection to the cell-status sidecar as
`attr(., "missing")`.

## Details

`catalogue` may also be a **custom identifier** for an `.ivt` file you
have placed in the ivt cache yourself (as `<id>.ivt` directly in
[ivt_cache_dir("ivt")](https://mountainmath.github.io/canivt/reference/ivt_cache_dir.md),
or as the only `.ivt` in a `<id>/` subfolder). Such files are used
directly, with no catalogue lookup or download – handy for tables that
are not on either index, or for local experiments.

For an ad-hoc table on neither index, pass a **named** length-one vector
or list whose name is the local cache key and whose value is a URL or a
local file path to a (zipped or raw) `.ivt`:
`get_statcan_ivt(c(my_table = "~/Downloads/foo.zip"))`. The name keys
the cached Parquet; the value is fetched (URL) or copied in place (local
path, never moved), sniffed so a `.zip` is unzipped and a raw `.ivt`
used as-is, then decoded.

## See also

[`statcan_ivt_catalogue()`](https://mountainmath.github.io/canivt/reference/statcan_ivt_catalogue.md),
[`read_ivt()`](https://mountainmath.github.io/canivt/reference/read_ivt.md)

## Examples

``` r
# Downloads, decodes and caches. Returns NULL with a warning if offline
# (no error), so no try() is needed.
# \donttest{
ds <- get_statcan_ivt("98-10-0241-01")
#> Downloading <https://www150.statcan.gc.ca/n1/en/tbl/b2020/98100241.zip>
#> Decoding
#> /var/folders/z4/gcjq2cd93p3bs5bgp8j2vv240000gp/T//RtmpWcdupN/canivt_tmp_ivt/98-10-0241-01/98100241.ivt
# `ds` is an Arrow connection; query it lazily and then collect:
if (!is.null(ds) && requireNamespace("dplyr", quietly = TRUE)) {
  print(dplyr::collect(head(ds)))
}
#> # A tibble: 6 × 13
#>   geo_label geo_name geo_uid geo_level age   household period statistics housing
#> * <chr>     <chr>    <chr>   <chr>     <chr> <chr>     <chr>  <chr>      <chr>  
#> 1 Canada    Canada   2021A0… Country   Tota… Total - … Total… Number of… Total …
#> 2 Canada    Canada   2021A0… Country   Tota… Total - … Total… Number of… Total …
#> 3 Canada    Canada   2021A0… Country   Tota… Total - … Total… Number of… Total …
#> 4 Canada    Canada   2021A0… Country   Tota… Total - … Total… Number of… Total …
#> 5 Canada    Canada   2021A0… Country   Tota… Total - … Total… Number of… Total …
#> 6 Canada    Canada   2021A0… Country   Tota… Total - … Total… Number of… Total …
#> # ℹ 4 more variables: tenure <chr>, value <dbl>, symbol <fct>, status <fct>
# }
```
