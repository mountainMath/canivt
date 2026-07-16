# Onboarding custom IVT files

The `getting-started` and `borealis` vignettes pull tables from the two
indexes `canivt` knows about — the StatCan census datasets index and the
Borealis Dataverse. But an `.ivt` can just as easily arrive from
neither: a custom order someone emailed you, a file you downloaded by
hand, or a table hosted somewhere `canivt` cannot look up. This vignette
shows how to onboard such a file, whether it lives at a **custom URL**
or a **local file path**.

``` r

library(canivt)
```

## The direct route: `read_ivt()`

The core reader takes a path and does not care where the file came from.
Point it at a local `.ivt` and it returns the decoded table straight
away — no cache, no catalogue, no network:

``` r

tab <- read_ivt("~/Downloads/cro0172986_ct.7-2006-population.ivt")
tab
ivt_tidy(tab)          # labelled long table
```

This is all you need for a one-off look. To get the same cached-Parquet
workflow the other vignettes use — decode once, then query the Parquet
lazily with `dplyr` — route the file through
[`get_statcan_ivt()`](https://mountainmath.github.io/canivt/reference/get_statcan_ivt.md)
instead, as below.

## A file on your local disk

Pass
[`get_statcan_ivt()`](https://mountainmath.github.io/canivt/reference/get_statcan_ivt.md)
a **named** length-one vector: the *name* is the cache key you want to
file the table under, and the *value* is the path to your `.ivt` (or a
`.zip` containing one):

``` r

ds <- get_statcan_ivt(c(my_table = "~/Downloads/cro0172986_ct.7-2006-population.ivt"))
ds
```

The file is **copied** into the ivt cache (never moved), decoded,
written to Parquet under the key `my_table`, and handed back as an
[`arrow`](https://arrow.apache.org/docs/r/) dataset connection. A `.zip`
source is sniffed and unzipped automatically. The second call with the
same key skips the copy and decode entirely and returns the cached
Parquet.

## A file at a custom URL

The value can equally be a URL (anything containing `://`).
[`get_statcan_ivt()`](https://mountainmath.github.io/canivt/reference/get_statcan_ivt.md)
downloads it, sniffs whether it is a zip or a raw `.ivt`, decodes it and
caches the result exactly as for a local file:

``` r

ds <- get_statcan_ivt(c(my_table = "https://example.org/tables/cro0172986.zip"))
```

Because everything is keyed by the name you chose, a later
`get_statcan_ivt(c(my_table = ...))` — or simply reading the cached
Parquet — is instant and needs no network.

## Depositing files into the cache by hand

If you have several local `.ivt` files to work with, it can be tidier to
drop them into the ivt cache directly and refer to each by a custom id.
Place a file as `<id>.ivt` in the ivt cache directory (or as the only
`.ivt` inside an `<id>/` subfolder), then call `get_statcan_ivt("<id>")`
with no URL or path:

``` r

ivt_cache_dir("ivt")   # where to put the files
# e.g. copy ~/Downloads/foo.ivt to <ivt cache>/my_table.ivt

ds <- get_statcan_ivt("my_table")   # found locally, no download
```

[`list_ivt_cache()`](https://mountainmath.github.io/canivt/reference/list_ivt_cache.md)
enumerates everything currently in the cache — both the raw `.ivt`
inputs and the decoded Parquets — so you can see what has been
onboarded.

## A note on what gets kept

By default `get_statcan_ivt(keep_ivt = FALSE)` decodes from a temporary
copy of the `.ivt` and keeps only the parsed Parquet, minimising the
storage footprint. Pass `keep_ivt = TRUE` to persist the raw `.ivt` in
the ivt cache as well (handy if you may want to re-decode it later with
different options, e.g. `geo_attributes = TRUE`). Either way the Parquet
is cached, so routine querying never re-reads the `.ivt`.

## Recap

``` r

library(canivt)

# one-off decode, no caching
tab <- read_ivt("~/Downloads/foo.ivt")

# cached-Parquet workflow, keyed by a name you choose:
get_statcan_ivt(c(my_table = "~/Downloads/foo.ivt"))          # local path
get_statcan_ivt(c(my_table = "https://example.org/foo.zip"))  # custom URL

# or deposit <id>.ivt in the cache and refer to it by id
get_statcan_ivt("my_table")
```

The same reader decodes every vintage through one path, so a custom
order onboards exactly like a catalogue table. See
[`?get_statcan_ivt`](https://mountainmath.github.io/canivt/reference/get_statcan_ivt.md)
and
[`?read_ivt`](https://mountainmath.github.io/canivt/reference/read_ivt.md)
for the full API, and
[`vignette("getting-started")`](https://mountainmath.github.io/canivt/articles/getting-started.md)
for the StatCan-catalogue workflow.
