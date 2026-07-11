# Prune files from the canivt cache

Deletes raw `.ivt` inputs and/or parsed data Parquets from the cache.
The target files can be given three ways (combinable):

## Usage

``` r
prune_ivt_cache(
  x = NULL,
  kind = NULL,
  language = NULL,
  sidecars = TRUE,
  dry_run = FALSE
)
```

## Arguments

- x:

  A character vector of catalogue numbers / cache keys, **or** a data
  frame from
  [`list_ivt_cache()`](https://mountainmath.github.io/canivt/reference/list_ivt_cache.md)
  (its `path` column is used), or `NULL` (all listed files, subject to
  `kind`/`language`).

- kind:

  Restrict to `"ivt"` and/or `"parquet"` files. `NULL` = both.

- language:

  Restrict Parquets to these languages (`"en"`/`"fr"`); `.ivt` files
  (language `NA`) are excluded when `language` is set. `NULL` = all.

- sidecars:

  Also delete a `<key>_members.parquet` sidecar once no Parquet
  references it (default `TRUE`).

- dry_run:

  If `TRUE`, report what would be removed without deleting.

## Value

Invisibly, a tibble of the removed (or, for `dry_run`, matched) files
with `kind` (`"ivt"`/`"parquet"`/`"sidecar"`), `path` and `bytes`.

## Details

- **catalogue numbers / cache keys** via `x` (a character vector),
  matched as in
  [`list_ivt_cache()`](https://mountainmath.github.io/canivt/reference/list_ivt_cache.md)
  (normalised key or catalogue number, exact or prefix);

- **format / language filters** via `kind` (`"ivt"` / `"parquet"`) and
  `language` (`"en"` / `"fr"`);

- a **filtered listing** via `x` (a data frame from
  [`list_ivt_cache()`](https://mountainmath.github.io/canivt/reference/list_ivt_cache.md),
  e.g. `list_ivt_cache() |> dplyr::filter(census_year == 2016)`):
  exactly its `path` files are removed.

With no `x`/`kind`/`language`, **every** listed cache file is targeted
(the member sidecars and the catalogue cache are never touched here).
When a Parquet is removed and no remaining Parquet references its shared
`<key>_members.parquet` sidecar, the orphaned sidecar is removed too
(`sidecars = TRUE`); emptied per-table `.ivt` folders are cleaned up.

## See also

[`list_ivt_cache()`](https://mountainmath.github.io/canivt/reference/list_ivt_cache.md)
