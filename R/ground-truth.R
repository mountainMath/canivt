# INTERNAL — ground-truth scraping from the StatCan Beyond 20/20 HTML viewer.
#
# These functions are not exported; they exist to build validation fixtures for
# the binary decoder, the same way the 1991 age x sex ground truth was scraped
# by hand. They read the public "Rp-eng.cfm" data-table viewer that the
# catalogue's `http_url` redirects to.
#
# The viewer renders a 2-D pivot of the table: one dimension on the rows, one on
# the columns (their member labels live in each cell's `title` attribute as
# `[Row N: ...] [Column M: ...]`, with N/M the 1-based member position), the
# geography fixed by the `GID` (`d0`) selector, and every other dimension fixed
# by a `d1`..`dN` selector (option value = 0-based member index). The pivot state
# is driven entirely by GET query parameters, so a slice is one URL fetch.
#
# Layout has been verified identical across the 1991, 2001 and 2006 viewers; the
# parser keys off stable ids (`table#tabulation`, `select#d0[name=GID]`, the cell
# `title` text) rather than year-specific markup.

# Resolve the Rp-eng.cfm viewer URL for a catalogue number by following the
# URLRedirect from its catalogue `http_url`. `catalogue_tbl` may be supplied to
# avoid re-reading the catalogue.
ivt_gt_viewer_url <- function(catalogue, catalogue_tbl = NULL) {
  ivt_require_scrape_pkgs()
  if (is.null(catalogue_tbl)) catalogue_tbl <- statcan_ivt_catalogue(quiet = TRUE)
  row <- ivt_lookup_catalogue_in(catalogue_tbl, catalogue)
  http_url <- ivt_abs_url(row$http_url)

  # URLRedirect answers a 302 to the real viewer; capture the Location header.
  loc <- ivt_gt_redirect_location(http_url)
  if (is.na(loc)) cli::cli_abort("Could not resolve the HTML viewer URL for {.val {catalogue}}.")
  ivt_abs_url(loc)
}

# Follow a single redirect and return the Location (absolute or site-relative),
# or NA if the URL is already a 200.
ivt_gt_redirect_location <- function(url) {
  if (requireNamespace("httr2", quietly = TRUE)) {
    # URLRedirect.cfm 302s to a 404 page for HEAD requests, so use GET.
    resp <- httr2::req_perform(
      httr2::req_error(
        httr2::req_options(httr2::request(url), followlocation = FALSE),
        is_error = function(resp) FALSE))
    loc <- httr2::resp_header(resp, "location")
    return(if (is.null(loc)) NA_character_ else loc)
  }
  # base fallback: HEAD via curl is awkward, so read headers from a GET.
  h <- curlGetHeaders(url, verify = TRUE)
  loc <- grep("^[Ll]ocation:", h, value = TRUE)
  if (!length(loc)) return(NA_character_)
  trimws(sub("^[Ll]ocation:", "", loc[length(loc)]))
}

# Scrape one pivot slice: the table for geography `gid` (and any `fixed` dimension
# member overrides, a named list like list(d1 = 1L)). Returns a tidy tibble with
# one row per data cell.
ivt_gt_slice <- function(viewer_url, gid = NULL, fixed = NULL) {
  params <- list()
  if (!is.null(gid)) params$GID <- gid
  if (length(fixed)) params[names(fixed)] <- fixed
  url <- ivt_gt_set_params(viewer_url, params)
  ivt_gt_parse_table(ivt_read_html(url))
}

# Build ground truth across geographies (default pivot, every fixed dim at its
# first member). `gids` selects geographies by their GID option value; when NULL
# the first `max_geos` geographies are used (NULL = all). Returns the row-bound
# tidy table; the data columns are named by the slugged HTML dimension names with
# a parallel `<slug>_id` member-position column for label-independent joins.
ivt_ground_truth <- function(catalogue, gids = NULL, max_geos = 8L,
                             catalogue_tbl = NULL, quiet = FALSE) {
  viewer_url <- ivt_gt_viewer_url(catalogue, catalogue_tbl)
  geos <- ivt_gt_geographies(ivt_read_html(viewer_url))
  if (is.null(gids)) {
    gids <- geos$gid
    if (!is.null(max_geos)) gids <- utils::head(gids, max_geos)
  }
  parts <- lapply(gids, function(g) {
    if (!quiet) cli::cli_inform("Scraping GID {g}")
    ivt_gt_slice(viewer_url, gid = g)
  })
  out <- do.call(rbind, parts)
  tibble::as_tibble(out)
}

# ---- HTML parsing -----------------------------------------------------------

# Geography selector (d0) as a tibble(gid, label).
ivt_gt_geographies <- function(doc) {
  opt <- rvest::html_elements(doc, "select#d0 option, select[name='GID'] option")
  tibble::tibble(
    gid   = rvest::html_attr(opt, "value"),
    label = trimws(rvest::html_text2(opt))
  )
}

# Fixed (non-displayed) dimensions: the d1..dN selectors and their current
# member. tibble(param, name, member_id, member_label) where member_id is the
# 1-based position (option value + 1).
ivt_gt_fixed_dims <- function(doc) {
  sels <- rvest::html_elements(doc, "select[id^='d']")
  sels <- sels[rvest::html_attr(sels, "name") != "GID"]
  if (!length(sels)) {
    return(tibble::tibble(param = character(), name = character(),
                          member_id = integer(), member_label = character()))
  }
  parse_one <- function(s) {
    param <- rvest::html_attr(s, "name")
    lab <- rvest::html_element(doc, sprintf("label[for='%s']", rvest::html_attr(s, "id")))
    name <- if (length(lab)) {
      t <- rvest::html_attr(lab, "title")
      if (is.na(t)) trimws(rvest::html_text2(lab)) else t
    } else param
    opts <- rvest::html_elements(s, "option")
    sel <- which(!is.na(rvest::html_attr(opts, "selected")))
    if (!length(sel)) sel <- 1L
    tibble::tibble(param = param, name = name,
                   member_id = as.integer(rvest::html_attr(opts[sel[1]], "value")) + 1L,
                   member_label = trimws(rvest::html_text2(opts[sel[1]])))
  }
  do.call(rbind, lapply(sels, parse_one))
}

# Parse the displayed data table into a tidy tibble (one row per cell), folding
# in the fixed-dimension state and the geography.
ivt_gt_parse_table <- function(doc) {
  tab <- rvest::html_element(doc, "table#tabulation")
  if (length(tab) == 0L || inherits(tab, "xml_missing")) {
    cli::cli_abort("No data table (table#tabulation) found; the viewer URL or pivot state may be wrong.")
  }
  row_dim <- trimws(rvest::html_text2(rvest::html_element(tab, "th#col-0")))
  col_dims <- rvest::html_elements(tab, "th[id^='colgroup-']")
  col_dim <- paste(trimws(rvest::html_text2(col_dims)), collapse = " | ")

  cells <- rvest::html_elements(tab, "td[title^='[Row']")
  title <- rvest::html_attr(cells, "title")
  m <- regmatches(title, regexec(
    "\\[Row ([0-9]+): (.*?)\\] \\[Column ([0-9]+): (.*?)\\]", title))
  ok <- lengths(m) == 5L
  m <- m[ok]; cells <- cells[ok]
  if (!length(m)) cli::cli_abort("Could not parse any data cells from the table.")

  n <- length(m)
  row_id  <- as.integer(vapply(m, `[`, "", 2))
  row_lab <- trimws(vapply(m, `[`, "", 3))
  col_id  <- as.integer(vapply(m, `[`, "", 4))
  col_lab <- trimws(vapply(m, `[`, "", 5))
  value   <- ivt_gt_parse_value(rvest::html_text2(cells))

  # geography (selected d0 option)
  geo <- ivt_gt_geographies(doc)
  sel_gid <- rvest::html_attr(
    rvest::html_element(doc, "select#d0 option[selected], select[name='GID'] option[selected]"),
    "value")
  sel_lab <- geo$label[match(sel_gid, geo$gid)]
  fx <- ivt_gt_fixed_dims(doc)

  # unique slugs for every dimension column (row, col, each fixed dim)
  slugs <- ivt_gt_unique_slugs(c(row_dim, col_dim, fx$name))

  cols <- list(gid = rep(sel_gid, n), geo = rep(sel_lab, n))
  cols[[slugs[1]]] <- row_lab
  cols[[paste0(slugs[1], "_id")]] <- row_id
  cols[[slugs[2]]] <- col_lab
  cols[[paste0(slugs[2], "_id")]] <- col_id
  for (i in seq_len(nrow(fx))) {
    s <- slugs[2 + i]
    cols[[s]] <- rep(fx$member_label[i], n)
    cols[[paste0(s, "_id")]] <- rep(fx$member_id[i], n)
  }
  cols$value <- value
  tibble::as_tibble(cols)
}

# Slug a set of dimension names and disambiguate any collisions.
ivt_gt_unique_slugs <- function(names) {
  s <- vapply(names, ivt_gt_slug, "", USE.NAMES = FALSE)
  if (anyDuplicated(s)) s <- make.unique(s, sep = "")
  s
}

# Value text -> numeric. StatCan suppression symbols (.., ..., x, F, -) -> NA.
ivt_gt_parse_value <- function(x) {
  x <- trimws(x)
  num <- suppressWarnings(as.numeric(gsub("[, ]", "", x)))
  num
}

# Slug a dimension name the way the binary decoder does for its data columns:
# leading alphabetic word, lower-cased (falls back to make.names).
ivt_gt_slug <- function(name) {
  w <- tolower(sub("^[^A-Za-z]*([A-Za-z]+).*$", "\\1", name))
  if (!nzchar(w) || !grepl("^[a-z]+$", w)) make.names(name) else w
}

# ---- URL helpers ------------------------------------------------------------

# Replace/add query parameters in a URL (existing keys are overwritten, not
# duplicated — the viewer breaks on duplicate GID/dN params).
ivt_gt_set_params <- function(url, params) {
  if (!length(params)) return(url)
  split <- strsplit(url, "?", fixed = TRUE)[[1]]
  base <- split[1]
  q <- if (length(split) > 1L) split[2] else ""
  pairs <- if (nzchar(q)) strsplit(q, "&", fixed = TRUE)[[1]] else character()
  keys <- sub("=.*$", "", pairs)
  for (k in names(params)) {
    kv <- paste0(k, "=", params[[k]])
    if (k %in% keys) pairs[keys == k] <- kv else { pairs <- c(pairs, kv); keys <- c(keys, k) }
  }
  paste0(base, "?", paste(pairs, collapse = "&"))
}

# Look up a catalogue row in an already-loaded catalogue tibble (shares the
# normalisation rules of ivt_lookup_catalogue without re-scraping).
ivt_lookup_catalogue_in <- function(catalogue_tbl, catalogue) {
  want <- ivt_catalogue_norm(catalogue)
  norm <- ivt_catalogue_norm(catalogue_tbl$catalogue)
  hit <- which(norm == want)
  if (!length(hit)) hit <- which(startsWith(norm, want))
  if (!length(hit)) cli::cli_abort("No catalogue entry matches {.val {catalogue}}.")
  catalogue_tbl[hit[1L], , drop = FALSE]
}
