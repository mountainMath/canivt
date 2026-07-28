# High-level entry point: turn a catalogue number (or a custom identifier for a
# locally-deposited .ivt) into a connection to the parsed Parquet, downloading
# and decoding under the hood and caching both the raw .ivt (ivt cache) and the
# parsed Parquet (data cache).

#' Get a StatCan IVT table as a Parquet connection
#'
#' One-stop accessor: given a table id, this resolves the product (the
#' [statcan_ivt_catalogue()] first, then the [borealis_ivt_catalogue()] of custom
#' tabulations), downloads its `.ivt` (cached in the ivt cache), decodes it with
#' [read_ivt()], writes the tidy table to Parquet (cached in the data cache) and
#' returns an Arrow connection to that Parquet so the data can be queried lazily
#' (e.g. with `dplyr`) without loading it all into memory.
#'
#' `catalogue` may also be a **custom identifier** for an `.ivt` file you have
#' placed in the ivt cache yourself (as `<id>.ivt` directly in
#' [ivt_cache_dir("ivt")][ivt_cache_dir], or as the only `.ivt` in a `<id>/`
#' subfolder). Such files are used directly, with no catalogue lookup or
#' download -- handy for tables that are not on either index, or for local
#' experiments.
#'
#' For an ad-hoc table on neither index, pass a **named** length-one vector or
#' list whose name is the local cache key and whose value is a URL or a local
#' file path to a (zipped or raw) `.ivt`:
#' `get_statcan_ivt(c(my_table = "~/Downloads/foo.zip"))`. The name keys the
#' cached Parquet; the value is fetched (URL) or copied in place (local path,
#' never moved), sniffed so a `.zip` is unzipped and a raw `.ivt` used as-is,
#' then decoded.
#'
#' @param catalogue A StatCan catalogue number (e.g. `"98-10-0241-01"`,
#'   `"95F0436XCB2001003"`), a Borealis id (a filename like `"CD1T29M3"`, its
#'   DOI-qualified key like `"SP3/6DGOTF/CD1T29M3"`, or a numeric `file_id`), or a
#'   custom identifier matching a local `.ivt` in the ivt cache. Matching is case-
#'   and punctuation-insensitive. A bare Borealis filename that occurs in several
#'   datasets is ambiguous and aborts with the disambiguating keys. **A one-row
#'   tibble from [statcan_ivt_catalogue()] or [borealis_ivt_catalogue()]** may be
#'   passed instead of an id, routing straight to that row's source with no
#'   catalogue lookup. A **named** length-one vector/list (`c(key = "url-or-path")`)
#'   is a manual import: its name is the cache key and its value a URL or local
#'   file path to a zipped or raw `.ivt`.
#' @param geo_attributes Passed to [read_ivt()]: decode the full family-2
#'   geography attribute table (slower) so geographies can be labelled by name.
#' @param labels Passed to [ivt_write_parquet()]: write labelled columns
#'   (`TRUE`, default) or the compact integer-id table.
#' @param missing Passed to [read_ivt()]: additionally cache the flagged cells
#'   on their own as a `<key>_<lang>_missing.parquet` sidecar. Off by default
#'   because the cached table already carries them (see `complete`); the sidecar
#'   is only worth writing when the same cells are wanted in isolation. A cached
#'   Parquet with no sidecar is re-decoded when this is `TRUE`.
#' @param complete Passed to [read_ivt()]: cache the **published table** -- every
#'   grid coordinate, published zeros included, flagged cells carrying
#'   `symbol`/`status` and a `NA` value (`TRUE`, default). A Parquet cached in
#'   the older store-only form is re-decoded rather than answering with fewer
#'   rows.
#' @param dim_names Passed to [ivt_write_parquet()]: name the data-dimension
#'   columns by the full dimension label (`"label"`, default) or the terse
#'   structural slug (`"slug"`).
#' @param language Passed to [ivt_write_parquet()]: output labels and
#'   label-derived column names in English (`"en"`, default) or French (`"fr"`).
#' @param keep_ivt Persist the downloaded/imported raw `.ivt` in the ivt cache
#'   ([ivt_cache_dir("ivt")][ivt_cache_dir]). The default `FALSE` decodes the
#'   `.ivt` from a temporary copy and then discards it, keeping only the parsed
#'   Parquet (re-fetched if the Parquet is later rebuilt). A raw `.ivt` already
#'   persisted in the ivt cache is reused regardless of this flag.
#' @param refresh Re-download and re-parse even if cached outputs exist.
#' @param quiet Suppress progress messages.
#' @return An [arrow::open_dataset()] connection to the Parquet file. The Parquet
#'   path is attached as `attr(., "path")`; the resolved catalogue row (if any)
#'   as `attr(., "catalogue_row")`; the member-level table ([ivt_members()],
#'   read from the `_members.parquet` sidecar when present) as
#'   `attr(., "members")` -- [collect_ivt()] uses it to convert dimension
#'   columns into full-level factors -- and, when `missing = TRUE`, a lazy
#'   connection to the cell-status sidecar as `attr(., "missing")`.
#' @seealso [statcan_ivt_catalogue()], [read_ivt()]
#' @examples
#' # Downloads, decodes and caches. Returns NULL with a warning if offline
#' # (no error), so no try() is needed.
#' \donttest{
#' ds <- get_statcan_ivt("98-10-0241-01")
#' # `ds` is an Arrow connection; query it lazily and then collect:
#' if (!is.null(ds) && requireNamespace("dplyr", quietly = TRUE)) {
#'   print(dplyr::collect(head(ds)))
#' }
#' }
#' @export
get_statcan_ivt <- function(catalogue, geo_attributes = FALSE, labels = TRUE,
                            missing = FALSE, dim_names = c("slug", "label"),
                            language = "en",
                            keep_ivt = FALSE, refresh = FALSE, quiet = FALSE,
                            complete = TRUE)
  ivt_offline_grace({
  if (!requireNamespace("arrow", quietly = TRUE)) {
    cli::cli_abort("Package {.pkg arrow} is required to open the parsed Parquet.")
  }
  dim_names <- match.arg(dim_names)
  language <- ivt_norm_lang(language)
  # `catalogue` may be an id string, a one-row catalogue tibble (from
  # statcan_ivt_catalogue() / borealis_ivt_catalogue()), or a NAMED length-one
  # vector/list mapping a cache key -> a manual URL/path source. Derive a stable
  # string id / cache key.
  manual <- ivt_manual_input(catalogue)
  id  <- if (is.null(manual)) ivt_input_id(catalogue) else manual$key
  key <- ivt_catalogue_key(id)
  # the language marker lets the English and French Parquets of one table coexist
  parquet <- file.path(ivt_cache_dir("data"),
                       paste0(key, "_", language, ".parquet"))

  # A cached Parquet answers the request only if it also carries what was asked
  # for: a table cached without the cell-status sidecar cannot supply it, so
  # `missing = TRUE` re-decodes rather than quietly returning less.
  if (!refresh && file.exists(parquet) &&
      (!isTRUE(missing) || file.exists(ivt_missing_path(parquet))) &&
      (!isTRUE(complete) || ivt_parquet_is_complete(parquet))) {
    return(ivt_parquet_connection(parquet, NULL))
  }

  # Where the raw .ivt lands: the persistent ivt cache when `keep_ivt`, else a
  # per-session temp folder (decoded then discarded).
  dest_dir <- if (isTRUE(keep_ivt)) file.path(ivt_cache_dir("ivt"), key)
              else file.path(tempdir(), "canivt_tmp_ivt", key)
  row <- NULL

  if (!is.null(manual)) {
    # Manual source: fetch/copy the given URL or local path into dest_dir.
    ivt_path <- ivt_manual_download(manual$source, key, dest_dir = dest_dir,
                                    overwrite = refresh, quiet = quiet)
  } else {
    # 1. A raw .ivt already in the ivt cache takes precedence (reused even when
    #    keep_ivt is FALSE -- it is already on disk).
    ivt_path <- ivt_find_cached_ivt(id)
    # 2. Otherwise resolve via the catalogues (StatCan first, Borealis fallback)
    #    and download. A row input routes straight to its own source.
    if (is.na(ivt_path)) {
      src <- ivt_resolve_source(catalogue, quiet = quiet)
      row <- src$row
      ivt_path <- src$download(key, refresh, quiet, dest_dir)
    } else if (!quiet) {
      cli::cli_inform("Using local IVT {.path {ivt_path}}")
    }
  }

  # 3. Decode and cache the tidy table as Parquet.
  if (!quiet) cli::cli_inform("Decoding {.path {ivt_path}}")
  tab <- read_ivt(ivt_path, geo_attributes = geo_attributes, missing = missing,
                  complete = complete)
  ivt_write_parquet(tab, path = parquet, labels = labels, dim_names = dim_names,
                    language = language)

  ivt_parquet_connection(parquet, row)
})

#' List the canivt cache contents
#'
#' Lists the raw `.ivt` inputs (in the ivt cache) and the parsed data Parquets
#' (in the data cache), one row per file, enriched with catalogue metadata
#' (matched product number, title, census year, topic) when the file's cache key
#' matches a product in the [statcan_ivt_catalogue()]. The member sidecars
#' (`_members.parquet`), the cell-status sidecars (`_missing.parquet`) and the
#' catalogue cache itself are infrastructure and are not listed.
#'
#' @param catalogue A catalogue tibble (from [statcan_ivt_catalogue()]) used to
#'   enrich the listing. `NULL` (default) reads the **cached** catalogue if one
#'   exists and skips enrichment otherwise -- it never triggers a scrape, so this
#'   function works offline.
#' @return A tibble with one row per cached file: `kind` (`"ivt"` or
#'   `"parquet"`), `key` (the cache key -- the catalogue number for downloaded
#'   tables, the folder/file name otherwise), `language` (`"en"`/`"fr"` for a
#'   language-marked Parquet, `NA` for `.ivt` files and old unmarked Parquets),
#'   `path`, `bytes`, `modified`, and the catalogue columns `catalogue`, `title`,
#'   `census_year`, `topic` (`NA` when the key matches no product).
#' @seealso [get_statcan_ivt()], [statcan_ivt_catalogue()]
#' @examples
#' # Lists whatever is in the configured cache directories (empty when unset):
#' list_ivt_cache()
#' @export
list_ivt_cache <- function(catalogue = NULL) {
  ivt_dir  <- ivt_cache_dir("ivt",  create = FALSE)
  data_dir <- ivt_cache_dir("data", create = FALSE)
  norm <- function(p) normalizePath(p, winslash = "/", mustWork = FALSE)

  # raw .ivt inputs: <ivt_dir>/<key>/<file>.ivt, or a flat <key>.ivt. The key is
  # the per-table folder name (the .ivt inside can be named differently), or the
  # file stem when it sits directly in the cache root.
  ivt_files <- list.files(ivt_dir, pattern = "\\.ivt$", full.names = TRUE,
                          recursive = TRUE, ignore.case = TRUE)
  ivt_key <- vapply(ivt_files, function(f)
    if (norm(dirname(f)) == norm(ivt_dir)) tools::file_path_sans_ext(basename(f))
    else basename(dirname(f)), "")

  # parsed data Parquets: <data_dir>/<key>[_en|_fr].parquet. Drop the member
  # and cell-status sidecars and the catalogue cache (not data tables).
  pq <- list.files(data_dir, pattern = "\\.parquet$", full.names = TRUE,
                   ignore.case = TRUE)
  pq <- pq[!grepl("_(members|missing)\\.parquet$", pq, ignore.case = TRUE)]
  pq <- pq[!(basename(pq) %in% c("statcan_ivt_catalogue.parquet",
                                 "borealis_ivt_catalogue.parquet"))]
  pq_stem <- tools::file_path_sans_ext(basename(pq))
  pq_lang <- rep(NA_character_, length(pq)); pq_key <- pq_stem
  m <- regmatches(pq_stem, regexec("^(.*)_(en|fr)$", pq_stem, ignore.case = TRUE))
  for (i in seq_along(pq)) if (length(m[[i]]) == 3L) {
    pq_key[i] <- m[[i]][2]; pq_lang[i] <- tolower(m[[i]][3])
  }

  df <- data.frame(
    kind     = c(rep("ivt", length(ivt_files)), rep("parquet", length(pq))),
    key      = c(unname(ivt_key), pq_key),
    language = c(rep(NA_character_, length(ivt_files)), pq_lang),
    path     = c(ivt_files, pq),
    stringsAsFactors = FALSE)

  # file stats + catalogue enrichment columns, typed and 0-row-safe (rep(., n))
  n <- nrow(df)
  info <- file.info(df$path)
  df$bytes       <- if (n) info$size  else numeric(0)
  df$modified    <- if (n) info$mtime else as.POSIXct(character(0))
  df$catalogue   <- rep(NA_character_, n)
  df$title       <- rep(NA_character_, n)
  df$census_year <- rep(NA_integer_, n)
  df$topic       <- rep(NA_character_, n)

  if (n) {
    if (is.null(catalogue)) catalogue <- ivt_cached_catalogue(data_dir)
    key_norm <- ivt_catalogue_norm(df$key)
    if (!is.null(catalogue) && nrow(catalogue) &&
        "catalogue" %in% names(catalogue)) {
      cat_norm <- ivt_catalogue_norm(catalogue$catalogue)
      idx <- match(key_norm, cat_norm)                       # exact first
      for (i in which(is.na(idx))) {                         # then prefix
        h <- which(startsWith(cat_norm, key_norm[i]))
        if (length(h)) idx[i] <- h[1L]
      }
      df$catalogue   <- catalogue$catalogue[idx]
      df$title       <- catalogue$title[idx]
      df$census_year <- catalogue$census_year[idx]
      df$topic       <- catalogue$topic[idx]
    }
    # Borealis-sourced files: fill still-unmatched rows from the cached Borealis
    # catalogue (matched on the sanitised key, then file_id, then filename stem).
    bor <- ivt_cached_borealis_catalogue(data_dir)
    if (!is.null(bor) && nrow(bor)) {
      bkey  <- ivt_catalogue_norm(bor$key)
      bid   <- ivt_catalogue_norm(bor$file_id)
      bstem <- ivt_catalogue_norm(bor$file_stem)
      for (i in which(is.na(df$catalogue) & is.na(df$title))) {
        h <- which(bkey == key_norm[i])
        if (!length(h)) h <- which(bid == key_norm[i])
        if (!length(h)) h <- which(bstem == key_norm[i])
        if (length(h)) {
          df$catalogue[i] <- bor$key[h[1L]]
          df$title[i]     <- bor$dataset_name[h[1L]]
        }
      }
    }
  }

  df <- df[order(df$key, df$kind, df$language), , drop = FALSE]
  tibble::as_tibble(df[c("kind", "key", "language", "catalogue", "title",
                         "census_year", "topic", "bytes", "modified", "path")])
}

# The cached catalogue tibble read directly from the data cache (no scrape), or
# NULL when there is no cache / arrow is unavailable.
ivt_cached_catalogue <- function(data_dir = ivt_cache_dir("data", create = FALSE)) {
  cf <- file.path(data_dir, "statcan_ivt_catalogue.parquet")
  if (!file.exists(cf) || !requireNamespace("arrow", quietly = TRUE)) return(NULL)
  tryCatch(tibble::as_tibble(arrow::read_parquet(cf)), error = function(e) NULL)
}

# The cached Borealis catalogue read directly from the data cache (no search),
# or NULL when there is no cache / arrow is unavailable.
ivt_cached_borealis_catalogue <- function(data_dir = ivt_cache_dir("data", create = FALSE)) {
  cf <- file.path(data_dir, "borealis_ivt_catalogue.parquet")
  if (!file.exists(cf) || !requireNamespace("arrow", quietly = TRUE)) return(NULL)
  tryCatch(tibble::as_tibble(arrow::read_parquet(cf)), error = function(e) NULL)
}

# Which listing rows match any of `wants` (catalogue numbers / cache keys), on
# the normalised `key` or enriched `catalogue`, exact or prefix (either
# direction, so "98-10-0241" matches key "98100241" and catalogue
# "98-10-0241-01").
ivt_cache_match <- function(rows, wants) {
  wn <- ivt_catalogue_norm(wants)
  wn <- wn[nzchar(wn)]
  if (!length(wn) || !nrow(rows)) return(rep(FALSE, nrow(rows)))
  kn <- ivt_catalogue_norm(rows$key)
  cn <- ivt_catalogue_norm(ifelse(is.na(rows$catalogue), "", rows$catalogue))
  hit <- function(a) vapply(seq_along(a), function(i) {
    if (!nzchar(a[i])) return(FALSE)
    any(a[i] == wn | startsWith(a[i], wn) | startsWith(wn, a[i]))
  }, logical(1))
  hit(kn) | hit(cn)
}

#' Prune files from the canivt cache
#'
#' Deletes raw `.ivt` inputs and/or parsed data Parquets from the cache. The
#' target files can be given three ways (combinable):
#'
#' - **catalogue numbers / cache keys** via `x` (a character vector), matched as
#'   in [list_ivt_cache()] (normalised key or catalogue number, exact or prefix);
#' - **format / language filters** via `kind` (`"ivt"` / `"parquet"`) and
#'   `language` (`"en"` / `"fr"`);
#' - a **filtered listing** via `x` (a data frame from [list_ivt_cache()], e.g.
#'   `list_ivt_cache() |> dplyr::filter(census_year == 2016)`): exactly its `path`
#'   files are removed.
#'
#' With no `x`/`kind`/`language`, **every** listed cache file is targeted (the
#' member sidecars and the catalogue cache are never touched here). When a
#' Parquet is removed and no remaining Parquet references its shared
#' `<key>_members.parquet` sidecar, the orphaned sidecar is removed too
#' (`sidecars = TRUE`); emptied per-table `.ivt` folders are cleaned up.
#'
#' @param x A character vector of catalogue numbers / cache keys, **or** a data
#'   frame from [list_ivt_cache()] (its `path` column is used), or `NULL` (all
#'   listed files, subject to `kind`/`language`).
#' @param kind Restrict to `"ivt"` and/or `"parquet"` files. `NULL` = both.
#' @param language Restrict Parquets to these languages (`"en"`/`"fr"`); `.ivt`
#'   files (language `NA`) are excluded when `language` is set. `NULL` = all.
#' @param sidecars Also delete a `<key>_members.parquet` /
#'   `<key>_<lang>_missing.parquet` sidecar once no Parquet references it
#'   (default `TRUE`).
#' @param dry_run If `TRUE`, report what would be removed without deleting.
#' @return Invisibly, a tibble of the removed (or, for `dry_run`, matched) files
#'   with `kind` (`"ivt"`/`"parquet"`/`"sidecar"`), `path` and `bytes`.
#' @seealso [list_ivt_cache()]
#' @examples
#' # Preview what a prune would remove without deleting anything:
#' prune_ivt_cache(dry_run = TRUE)
#' @export
prune_ivt_cache <- function(x = NULL, kind = NULL, language = NULL,
                            sidecars = TRUE, dry_run = FALSE) {
  data_dir <- ivt_cache_dir("data", create = FALSE)
  ivt_dir  <- ivt_cache_dir("ivt",  create = FALSE)

  if (is.data.frame(x)) {
    rows <- x
    if (!"path" %in% names(rows))
      cli::cli_abort("Data frame {.arg x} must have a {.field path} column (from {.fn list_ivt_cache}).")
  } else {
    rows <- list_ivt_cache()
    if (!is.null(x)) rows <- rows[ivt_cache_match(rows, as.character(x)), , drop = FALSE]
  }
  if (!is.null(kind) && "kind" %in% names(rows))
    rows <- rows[rows$kind %in% kind, , drop = FALSE]
  if (!is.null(language) && "language" %in% names(rows))
    rows <- rows[!is.na(rows$language) & rows$language %in% language, , drop = FALSE]

  paths <- unique(rows$path[!is.na(rows$path) & file.exists(rows$path)])

  # orphaned sidecars (member tables and cell-status tables alike): those not
  # referenced by any Parquet that remains after `paths` are removed (also
  # sweeps pre-existing orphans).
  orphan <- character(0)
  all_side <- list.files(data_dir, pattern = "_(members|missing)\\.parquet$",
                         full.names = TRUE, ignore.case = TRUE)
  if (isTRUE(sidecars) && length(all_side)) {
    cur <- list_ivt_cache()
    remaining_pq <- cur$path[cur$kind == "parquet" & !(cur$path %in% paths)]
    keep <- normalizePath(unique(c(ivt_members_path(remaining_pq),
                                   ivt_missing_path(remaining_pq))),
                          mustWork = FALSE)
    orphan <- all_side[!(normalizePath(all_side, mustWork = FALSE) %in% keep)]
  }

  remove <- unique(c(paths, orphan))
  bytes <- file.info(remove)$size
  removed <- tibble::tibble(
    kind = ifelse(grepl("\\.ivt$", remove, ignore.case = TRUE), "ivt",
           ifelse(grepl("_(members|missing)\\.parquet$", remove, ignore.case = TRUE),
                  "sidecar", "parquet")),
    path = remove, bytes = bytes)

  total <- sum(removed$bytes, na.rm = TRUE)
  size <- format(structure(total, class = "object_size"), units = "auto")
  if (!nrow(removed)) {
    cli::cli_inform("No matching cache files to prune.")
    return(invisible(removed))
  }
  if (dry_run) {
    cli::cli_inform("Would remove {nrow(removed)} file{?s} ({size}).")
    return(invisible(removed))
  }

  unlink(remove)
  # remove now-empty per-table .ivt folders (never the ivt cache root itself)
  root <- normalizePath(ivt_dir, mustWork = FALSE)
  for (d in unique(dirname(paths[removed$kind == "ivt"]))) {
    if (normalizePath(d, mustWork = FALSE) == root) next
    if (dir.exists(d) && !length(list.files(d, all.files = TRUE, no.. = TRUE)))
      unlink(d, recursive = TRUE)
  }
  cli::cli_inform("Removed {nrow(removed)} file{?s} ({size}).")
  invisible(removed)
}

# Open the Parquet and attach provenance attributes (plus the member-level
# sidecar, when one was written, so collect_ivt() finds it on the connection
# and on any dplyr query built from it).
ivt_parquet_connection <- function(parquet, row) {
  ds <- arrow::open_dataset(parquet)
  attr(ds, "path") <- parquet
  attr(ds, "catalogue_row") <- row
  attr(ds, "members") <- ivt_read_members(ivt_members_path(parquet))
  # The cell-status sidecar can dwarf the data (a sparse crosstab's absent cells
  # outnumber its values), so attach it LAZILY -- an Arrow connection, not a
  # materialised tibble like the small member table.
  mp <- ivt_missing_path(parquet)
  if (file.exists(mp)) {
    md <- tryCatch(arrow::open_dataset(mp), error = function(e) NULL)
    if (!is.null(md)) attr(md, "path") <- mp
    attr(ds, "missing") <- md
  }
  ds
}

# Does a cached Parquet hold the PUBLISHED table (every grid coordinate, flagged
# cells carrying their symbol) or the older store-only form? A cache written
# before completion existed answers with fewer rows and no way to tell a
# suppressed cell from a zero, so it is re-decoded rather than reused.
ivt_parquet_is_complete <- function(parquet) {
  nm <- tryCatch(names(arrow::open_dataset(parquet)),
                 error = function(e) character(0))
  "symbol" %in% nm
}

# A filesystem-safe cache key for a catalogue number / custom id.
ivt_catalogue_key <- function(catalogue) {
  gsub("[^A-Za-z0-9._-]+", "_", catalogue)
}

# Normalise a catalogue number for matching (drop punctuation, upper-case).
ivt_catalogue_norm <- function(x) toupper(gsub("[^A-Za-z0-9]", "", x))

# Find a locally-deposited .ivt for a custom identifier; NA if none.
ivt_find_cached_ivt <- function(id) {
  cache <- ivt_cache_dir("ivt", create = FALSE)
  flat <- list.files(cache, pattern = "\\.ivt$", full.names = TRUE,
                     ignore.case = TRUE)
  # per-table subfolder: the id verbatim, and its filesystem-safe key form (the
  # download folder for e.g. Borealis DOI keys, which contain slashes).
  subdirs <- unique(c(id, ivt_catalogue_key(id)))
  sub <- list.files(file.path(cache, subdirs), pattern = "\\.ivt$",
                    full.names = TRUE, ignore.case = TRUE)
  cands <- c(file.path(cache, paste0(id, c(".ivt", ".IVT"))),
             flat[ivt_catalogue_norm(tools::file_path_sans_ext(basename(flat))) ==
                    ivt_catalogue_norm(id)],
             sub)
  cands <- cands[file.exists(cands)]
  if (length(cands)) cands[1] else NA_character_
}

# Detect a manual-source input to get_statcan_ivt(): a NAMED length-one vector
# or list mapping a local cache key to a URL or local file path. Returns
# list(key=, source=) for such an input, or NULL for an ordinary id / catalogue
# row. A named input with != 1 entry, or a blank name/value, aborts.
ivt_manual_input <- function(x) {
  if (is.data.frame(x)) return(NULL)
  nm <- names(x)
  if (is.null(nm) || !any(nzchar(nm))) return(NULL)
  if (length(x) != 1L)
    cli::cli_abort(c(
      "A named manual IVT source must have exactly one entry (got {length(x)}).",
      i = "Call {.fn get_statcan_ivt} once per table."))
  key <- nm[[1L]]
  src <- x[[1L]]
  if (!is.character(src) || length(src) != 1L)
    src <- tryCatch(as.character(src), error = function(e) NA_character_)
  if (!nzchar(key))
    cli::cli_abort("The manual IVT source name (used as the cache key) must be non-empty.")
  if (length(src) != 1L || is.na(src) || !nzchar(src))
    cli::cli_abort("The manual IVT source (a URL or local file path) must be a non-empty string.")
  list(key = key, source = src)
}

# Import a manual source (a URL, or a local path to a zipped or raw .ivt) into
# `dest_dir` and return the local .ivt path. Mirrors statcan_ivt_download()'s
# sniff-and-store (ivt_store_download): a URL is downloaded to a tempfile first;
# a local file is passed through directly (copied/unzipped in place, never
# moved). Reuses an existing .ivt in `dest_dir` unless `overwrite`.
ivt_manual_download <- function(source, key, dest_dir = NULL, overwrite = FALSE,
                                quiet = FALSE) {
  if (is.null(dest_dir)) dest_dir <- file.path(ivt_cache_dir("ivt"), key)
  dir.create(dest_dir, showWarnings = FALSE, recursive = TRUE)

  existing <- list.files(dest_dir, pattern = "\\.ivt$", full.names = TRUE,
                         ignore.case = TRUE)
  if (length(existing) && !overwrite) return(existing[1])

  out_name <- paste0(key, ".ivt")
  if (grepl("://", source)) {
    if (!quiet) cli::cli_inform("Downloading {.url {source}}")
    tmp <- tempfile(fileext = ".bin")
    on.exit(unlink(tmp), add = TRUE)
    ivt_download_to(source, tmp, quiet = quiet)
    return(ivt_store_download(tmp, dest_dir, out_name))
  }
  path <- path.expand(source)
  if (!file.exists(path))
    cli::cli_abort(c(
      "Manual IVT source {.path {source}} does not exist.",
      i = "Provide a URL (containing {.val ://}) or an existing local file path."))
  if (!quiet) cli::cli_inform("Importing local IVT {.path {path}}")
  ivt_store_download(path, dest_dir, out_name)
}

# Resolve a catalogue number to its StatCan catalogue row. Returns NULL when no
# product matches and `error = FALSE`; aborts otherwise.
ivt_lookup_catalogue <- function(catalogue, quiet = FALSE, error = TRUE) {
  catl <- ivt_build_catalogue(quiet = quiet)
  want <- ivt_catalogue_norm(catalogue)
  norm <- ivt_catalogue_norm(catl$catalogue)
  hit <- which(norm == want)
  if (!length(hit)) hit <- which(startsWith(norm, want))
  if (!length(hit)) {
    if (!error) return(NULL)
    cli::cli_abort(c(
      "No IVT product matches catalogue {.val {catalogue}}.",
      i = "It is also not a local .ivt in the ivt cache ({.path {ivt_cache_dir('ivt', create = FALSE)}}).",
      i = "See {.fn statcan_ivt_catalogue} for the available products."
    ))
  }
  if (length(hit) > 1L) {
    cli::cli_warn(c(
      "Catalogue {.val {catalogue}} matches {length(hit)} products; using the first.",
      i = "Matches: {.val {catl$catalogue[hit]}}"
    ))
  }
  catl[hit[1L], , drop = FALSE]
}

# Resolve a table id (or a pre-fetched catalogue row) to a source (StatCan
# catalogue, else Borealis) and a download closure. Aborts if neither catalogue
# has it. StatCan takes precedence for the ~800 products mirrored in both
# (official source, no API key).
ivt_resolve_source <- function(catalogue, quiet = FALSE) {
  if (is.data.frame(catalogue)) return(ivt_row_source(catalogue))
  row <- ivt_lookup_catalogue(catalogue, quiet = quiet, error = FALSE)
  if (!is.null(row)) {
    return(list(source = "statcan", row = row,
      download = function(key, overwrite, quiet, dest_dir = NULL)
        ivt_statcan_download_impl(row$download_url, key = key, dest_dir = dest_dir,
                                  overwrite = overwrite, quiet = quiet)))
  }
  brow <- ivt_lookup_borealis(catalogue, quiet = quiet)
  if (!is.null(brow)) {
    return(list(source = "borealis", row = brow,
      download = function(key, overwrite, quiet, dest_dir = NULL)
        borealis_ivt_download(brow, key = key, dest_dir = dest_dir,
                              overwrite = overwrite, quiet = quiet)))
  }
  cli::cli_abort(c(
    "No IVT product matches {.val {catalogue}}.",
    i = "It is not in the StatCan catalogue, the Borealis catalogue, or the local ivt cache ({.path {ivt_cache_dir('ivt', create = FALSE)}}).",
    i = "See {.fn statcan_ivt_catalogue} and {.fn borealis_ivt_catalogue} for the available products."
  ))
}

# TRUE when a one-row catalogue tibble is a Borealis row (vs a StatCan row),
# distinguished by the Borealis-only `file_id`/`dataset_doi` columns.
ivt_row_is_borealis <- function(row) {
  all(c("file_id", "dataset_doi") %in% names(row))
}

# Build a source descriptor (source/row/download) directly from a pre-fetched
# catalogue row, with no catalogue lookup. Accepts a one-row tibble from either
# statcan_ivt_catalogue() or borealis_ivt_catalogue().
ivt_row_source <- function(row) {
  if (nrow(row) != 1L)
    cli::cli_abort("A catalogue row must have exactly one row (got {nrow(row)}).")
  if (ivt_row_is_borealis(row)) {
    return(list(source = "borealis", row = row,
      download = function(key, overwrite, quiet, dest_dir = NULL)
        borealis_ivt_download(row, key = key, dest_dir = dest_dir,
                              overwrite = overwrite, quiet = quiet)))
  }
  if (all(c("catalogue", "download_url") %in% names(row))) {
    return(list(source = "statcan", row = row,
      download = function(key, overwrite, quiet, dest_dir = NULL)
        ivt_statcan_download_impl(row$download_url, key = key, dest_dir = dest_dir,
                                  overwrite = overwrite, quiet = quiet)))
  }
  cli::cli_abort(c(
    "Unrecognised catalogue row.",
    i = "Pass a one-row tibble from {.fn statcan_ivt_catalogue} or {.fn borealis_ivt_catalogue}."
  ))
}

# The stable string id / cache key for a get_statcan_ivt() input, which may be an
# id string or a one-row catalogue tibble (its StatCan `catalogue` number or its
# Borealis `key`).
ivt_input_id <- function(x) {
  if (!is.data.frame(x)) return(as.character(x))
  if (nrow(x) != 1L)
    cli::cli_abort("A catalogue row must have exactly one row (got {nrow(x)}).")
  id <- if (ivt_row_is_borealis(x)) x$key else x$catalogue
  if (is.null(id) || !length(id) || is.na(id))
    cli::cli_abort(c(
      "Could not derive an id from the catalogue row.",
      i = "Pass a one-row tibble from {.fn statcan_ivt_catalogue} or {.fn borealis_ivt_catalogue}."
    ))
  as.character(id)
}

# Resolve a table id to its Borealis catalogue row, or NULL if Borealis has no
# such file (or its catalogue is unavailable -- no key/package). Matches on the
# canonical DOI-qualified `key`, then the unique `file_id`, then the bare
# filename stem; an ambiguous stem (the same name across datasets/editions)
# aborts with the disambiguating keys.
ivt_lookup_borealis <- function(catalogue, quiet = FALSE) {
  catl <- tryCatch(borealis_ivt_catalogue(quiet = quiet),
                   error = function(e) NULL)
  if (is.null(catl) || !nrow(catl)) return(NULL)
  want <- ivt_catalogue_norm(catalogue)

  hit <- which(ivt_catalogue_norm(catl$key) == want)
  if (!length(hit)) hit <- which(ivt_catalogue_norm(catl$file_id) == want)
  if (!length(hit)) hit <- which(ivt_catalogue_norm(catl$file_stem) == want)
  if (!length(hit)) return(NULL)

  # Collapse byte-identical duplicates (the same file mirrored across datasets,
  # e.g. EN/FR deposits): any copy will do. Only genuinely different content
  # (distinct md5 -- e.g. the same filename reused across editions) is ambiguous.
  if (length(hit) > 1L && length(unique(catl$md5[hit])) > 1L) {
    cli::cli_abort(c(
      "Borealis has {length(hit)} files matching {.val {catalogue}} (different datasets/editions).",
      i = "Re-request one by its full key, e.g. {.val {catl$key[hit[1]]}}:",
      i = "{.val {paste0(catl$key[hit], '  (', catl$dataset_name[hit], ')')}}"
    ))
  }
  catl[hit[1L], , drop = FALSE]
}

#' Download a StatCan IVT by its direct-download URL
#'
#' Downloads a `.ivt` (or its containing `.zip`) from a resolved
#' [statcan_ivt_resolve_url()] URL into the ivt cache and returns the local
#' `.ivt` path. The payload is sniffed: a `.zip` is unzipped, a raw IVT is kept
#' as-is.
#'
#' @param download_url A direct-download URL (a b2020 `.zip` or a
#'   `Download.cfm?PID=` endpoint), **or** a one-row [statcan_ivt_catalogue()]
#'   tibble (its `download_url` and, by default, its `catalogue` number as the
#'   cache key are used).
#' @param key Cache key used to name the per-table folder under the ivt cache.
#'   Optional when `download_url` is a catalogue row (defaults to the row's
#'   catalogue number).
#' @param dest_dir Directory the `.ivt` is written to. Defaults to a per-table
#'   folder under the ivt cache ([ivt_cache_dir("ivt")][ivt_cache_dir]);
#'   [get_statcan_ivt()] passes a temporary folder when `keep_ivt = FALSE`.
#' @param overwrite Re-download even if a `.ivt` already exists.
#' @param quiet Suppress the download message.
#' @return Path to the local `.ivt` file, or `NULL` (invisibly, with a warning)
#'   if the endpoint could not be reached.
#' @examples
#' # Downloads from Statistics Canada. Returns NULL with a warning if offline
#' # (no error), so no try() is needed.
#' \donttest{
#' url <- statcan_ivt_resolve_url("Alternative.cfm?PID=55701&EXT=IVT")
#' path <- statcan_ivt_download(url, key = "97-570-X1981004", dest_dir = tempdir())
#' }
#' @export
statcan_ivt_download <- function(download_url, key = NULL, dest_dir = NULL,
                                 overwrite = FALSE, quiet = FALSE) {
  ivt_offline_grace(
    ivt_statcan_download_impl(download_url, key = key, dest_dir = dest_dir,
                              overwrite = overwrite, quiet = quiet))
}

# Core StatCan download (raises `canivt_offline` on a connection failure); the
# exported statcan_ivt_download() wraps this, get_statcan_ivt()'s resolver calls
# it directly so the offline signal reaches that function's grace boundary.
ivt_statcan_download_impl <- function(download_url, key = NULL, dest_dir = NULL,
                                      overwrite = FALSE, quiet = FALSE) {
  if (is.data.frame(download_url)) {
    row <- download_url
    if (nrow(row) != 1L)
      cli::cli_abort("A catalogue row must have exactly one row (got {nrow(row)}).")
    if (is.null(key)) key <- ivt_catalogue_key(as.character(row$catalogue))
    download_url <- as.character(row$download_url)
  }
  if (is.null(key) || !nzchar(key))
    cli::cli_abort("{.arg key} is required when {.arg download_url} is a URL string.")

  if (is.null(dest_dir)) dest_dir <- file.path(ivt_cache_dir("ivt"), key)
  dir.create(dest_dir, showWarnings = FALSE, recursive = TRUE)

  existing <- list.files(dest_dir, pattern = "\\.ivt$", full.names = TRUE,
                         ignore.case = TRUE)
  if (length(existing) && !overwrite) return(existing[1])

  if (!quiet) cli::cli_inform("Downloading {.url {download_url}}")
  tmp <- tempfile(fileext = ".bin")
  on.exit(unlink(tmp), add = TRUE)
  ivt_download_to(download_url, tmp, quiet = quiet)
  ivt_store_download(tmp, dest_dir, paste0(key, ".ivt"))
}
