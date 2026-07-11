# canivt cache directories

canivt uses two optional cache locations, each controlled by an R option
(or the matching environment variable, which is read into the option
when the package loads so it can be set in `.Renviron`):

## Usage

``` r
ivt_cache_dir(which = c("ivt", "data"), create = TRUE)
```

## Arguments

- which:

  Which cache to resolve: `"ivt"` (raw downloads) or `"data"` (parsed
  Parquet + metadata).

- create:

  Create the directory if it does not exist? Default `TRUE`.

## Value

The cache directory path (a
[`tempdir()`](https://rdrr.io/r/base/tempfile.html) subfolder when the
option is unset).

## Details

- **`ivt`** – raw downloaded `.ivt` files, option `canivt.ivt_cache`
  (env var `CANIVT_IVT_CACHE`). When unset, downloads go to a
  per-session [`tempdir()`](https://rdrr.io/r/base/tempfile.html) folder
  and are discarded at the end of the session.

- **`data`** – parsed Parquet data and metadata that should persist
  across sessions, option `canivt.data_cache` (env var
  `CANIVT_DATA_CACHE`). When unset, parsed output goes to
  [`tempdir()`](https://rdrr.io/r/base/tempfile.html) (and is lost when
  the session ends; a one-time startup message points this out).

Set them either as options (e.g. in `.Rprofile`):
`options(canivt.data_cache = "~/canivt-cache")`, or as environment
variables (e.g. in `.Renviron`): `CANIVT_DATA_CACHE=~/canivt-cache`.
