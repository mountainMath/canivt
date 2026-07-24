# dev/ — range-harvest prototype

**Not part of the built package** (`^dev$` in `.Rbuildignore`). Experimental
tooling for a catalogue-wide metadata inventory that fetches only the front
metadata region of each remote `.ivt` instead of the whole file.

## What it does

`range-harvest.R` defines a **lazy, range-backed byte source** that presents
`length()` and `[` to the *unchanged* canivt parser (`ivt_family()` +
`ivt_f2_metadata()`), so the parser pulls exactly the bytes it addresses and the
data-page bulk is never fetched. Three backends, chosen by probing the URL:

| container | when | how |
|---|---|---|
| `raw-range` | server supports HTTP Range (Borealis after its 303→S3 redirect; most raw `.ivt`) | sparse 64 KiB chunk cache |
| `zip-deflate` | census `.zip` on www150 (member stored with DEFLATE) | fetch a **compressed prefix**, stream-inflate it (`rh_inflate.py`, `zlib` raw deflate); deflate is sequential so a small compressed prefix yields the uncompressed metadata prefix |
| `full-download` | server ignores Range and returns 200 (www12 `Download.cfm`) | reuse the body the probe already streamed (these are small files) |

`rh_inflate.py` — streaming raw-DEFLATE inflater (tolerates a truncated prefix).

## Read-through cache (`dev/harvest-cache/`, gitignored + rbuildignored)

Fetched bytes persist under `dev/harvest-cache/<id>/`, so a re-open reconstructs
the backend **from disk without touching the network** (`rh_open(..., cache =
TRUE)`, the default when an `id` is passed):

- `manifest.rds` — url, final_url, container, size, and the zip geometry
  (`window0`/`data0`/`csize`/member) needed to rebuild the backend cold.
- `raw-range` / `zip-store` → 64 KiB chunk files `c<idx>.bin` (sparse; only the
  chunks the parser touched).
- `zip-deflate` → `compressed.bin`, the fetched **compressed** prefix (small —
  3.5 MB for a 39.5 MB table — re-inflated on warm open, not the inflated bytes).
- `full-download` → `full.bin`.

Inventory columns `cache_bytes` / `from_cache` report cache hits; a warm re-run
shows `bytes_fetched = 0`, `n_requests = 0`. The cache doubles as an offline
corpus of exactly the metadata regions. `cache = FALSE` disables it.

## Provenance output (`out_dir`)

- `inventory_<source>.csv` — one row per file: **id, source, url, final_url**,
  container, logical_size, **bytes_fetched, pct_fetched, n_requests**, supported,
  family, n_dim, `dims` (packed `name:count|…`), n_geo, n_footnotes, status,
  warnings, fetched_at. Rewritten after every file (crash-safe).
- `meta/<id>.rds` — the full parsed metadata object + `{id, url, final_url}`.
- `frag/<id>.ivtfrag` — the fetched fragment (inflated/contiguous prefix, or the
  concatenated raw chunks), so the pulled bytes are reusable and traceable to the id.

## Usage

```r
devtools::load_all("~/R/canivt"); source("dev/range-harvest.R")
rh_harvest_catalogue("borealis", "~/data/ivt_harvest", limit = 50)
rh_harvest_catalogue("statcan",  "~/data/ivt_harvest", keys = c("98-10-0211-01", ...))
rh_harvest_one("id", "borealis", "https://…", out_dir = "~/data/ivt_harvest")
```

Per-file `timeout` (default 120 s) keeps one pathological file from stalling a
sweep: it is a wall-clock **deadline checked inside `rh_get`**, so a slow/hung file
trips a normal, catchable error in the network region and becomes an inventory row
— it never escapes the per-file handler and halts the batch (the failure mode of
the earlier `setTimeLimit(elapsed=)` approach). A catalogue run is also
**resume-safe**: `rh_harvest_catalogue(..., resume = TRUE)` (the default) skips keys
whose `meta/<id>.rds` already exists — a per-file meta is written only on success —
so a re-run retries **only** the failures (network drop, deadline) and re-serves
everything else from the read-through cache at zero network. `resume = FALSE` forces
a full re-harvest.

## Validated

Metadata byte-identical to a full local decode (dims/geographies/footnotes) on
`raw-range`, `zip-deflate`, and `full-download`. Payoff (bytes fetched / size):
39 MB census `.zip` → **8.9 %**; 55 MB modern Borealis raw → **1.0 %**; 6.8 MB →
8.3 %.

## Known limitations (follow-ups)

1. **Whole-file byte-scans.** A few older/survey vintages hit metadata fallbacks
   that scan the *entire* vector (`as.integer(raw)`: French-name marker,
   geo-DGUID scan). The reader materializes on demand, capped at
   `RH_MATERIALIZE_CAP` (96 MB) → above it the row is flagged `NEEDS-FULL-FETCH`
   (seen on the 452 MB `98-10-0425`). Bounding those scans to the front region in
   the parser would remove the cap.
2. **www12 `Download.cfm` has no Range support** → those (small) files download
   in full. The big tables are the www150 `.zip`s, which *do* range.
3. Zip members using a **data-descriptor** (sizes only in the central directory)
   aren't handled yet (would need an EOCD read); none seen so far.
