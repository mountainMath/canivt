# Network transport. StatCan's `www12.statcan.gc.ca` host (the census datasets
# index, `Download.cfm`, the B20/20 viewer) answers every plain request with a
# Cloudflare browser check, so a bare `download.file()` / `xml2::read_html()`
# gets a 403 page instead of the resource. The `safeconduct` package gets past
# that by opening a real browser when, and only when, a plain request is
# refused; it is a soft dependency (Suggests). Every network access in the
# package goes through these two helpers so the choice is made in ONE place:
#
#   ivt_fetch_file(url, destfile)  -- a file to disk
#   ivt_fetch_html(url)            -- a page as an `xml_document`
#
# With safeconduct installed they fetch through it (a plain request first, a
# browser only on a refusal); without it they fall back to base R and, when the
# refusal is a browser check, say how to install safeconduct. Either way a
# failure is raised as a classed `canivt_offline` error (see fallback.R), so the
# exported entry points' `ivt_offline_grace()` boundary is unchanged.
#
# A request carrying custom headers (the Borealis API key) never goes through
# safeconduct, whose transport has no header argument; Borealis does not
# challenge plain requests.
#
# On a host known to challenge (`IVT_BROWSER_HOSTS`) every request -- a page
# AND a file -- is an in-page read from a FRESH browser, retried on a challenge
# (`ivt_read_page()`); safeconduct's own download route (a document navigation
# to the file) is challenged every time there, its read route gets through
# once per browser (a `Download.cfm` answer is the bare .ivt, 2026-11-02). The
# read route carries the body as base64 inside one DevTools message, so it is
# for files up to a cap: tables of 49 KB to 24 MB arrive in 5-40 s, a 27.8 MB
# one (37 MB as base64) hangs the browser read past its timeout, reproducibly
# (2026-11-02). The route that handles any size
# -- the same in-page `fetch()`, handed to Chrome's download machinery as a
# Blob instead of returned through DevTools, 27 MB in 10 s -- is prototyped
# in safeconduct's `NOTE-path-scoped-challenge.md`; once `safeconduct::fetch()`
# downloads that way the file branch in `ivt_fetch_file()` goes. Measured
# on `www12` (2026-11-01/02): a headless pass at the host root takes ~1.6 s, the
# browser's first in-page read of a `/datasets/` page then gets through about
# half the time, and every further read from that same browser is challenged
# again, headed or not -- the path runs its own per-navigation check that a
# root pass does not clear. So a browser kept across reads is challenged on
# every read after its first, while a fresh browser per read with a retry
# scrapes the eleven index pages in ~3 minutes. Revisit when safeconduct
# passes the check at the URL itself.

# Is safeconduct installed? Isolated so tests can mock either branch.
ivt_has_safeconduct <- function() {
  requireNamespace("safeconduct", quietly = TRUE)
}

# Download `url` to `destfile`. Through safeconduct when installed and no
# custom `headers` are needed; otherwise `utils::download.file()`. Any failure
# (an error, a non-zero status, a missing file) is a `canivt_offline` error.
#
# Note on `Download.cfm?PID=` (the pre-2021 census tables): on 2026-11-01 the
# server answered it with a 301 to the datasets index for every client, a
# cleared real browser included; on 2026-11-02 it served the file again (to a
# real browser and to the in-page read below). A "page, not the file" failure
# here is that server-side state, not a transport problem. The in-page read is
# the only route through today and it is a small-file route (see the header):
# a large table is where safeconduct's Blob download is needed.
ivt_fetch_file <- function(url, destfile, quiet = FALSE, headers = NULL) {
  if (is.null(headers) && ivt_has_safeconduct()) {
    if (ivt_host_needs_browser(url)) {
      # the host lets a fresh browser's first in-page read through and
      # challenges a document navigation (safeconduct's download route) every
      # time, so the file comes back as a page read -- the bytes of the
      # response, which for `Download.cfm` is the bare .ivt
      resp <- tryCatch(ivt_read_page(url),
                       error = function(e) ivt_offline_abort(url, parent = e))
      if (!identical(resp$status_code, 200L))
        ivt_offline_abort(url, hint = c(x = paste0("'", ivt_url_host(url),
          "' answered HTTP status ", resp$status_code, ".")))
      if (grepl("html", resp$type %||% "", fixed = TRUE))
        ivt_offline_abort(url, hint = c(x = paste0("'", ivt_url_host(url),
          "' answered with a page, not the file.")))
      writeBin(resp$content, destfile)
      return(invisible(destfile))
    }
    tryCatch(safeconduct::fetch(url, destfile, quiet = quiet),
             error = function(e) ivt_offline_abort(url, parent = e))
    if (!file.exists(destfile)) ivt_offline_abort(url)
    return(invisible(destfile))
  }
  args <- list(url = url, destfile = destfile, mode = "wb", quiet = quiet)
  if (!is.null(headers)) args$headers <- headers
  status <- tryCatch(
    suppressWarnings(do.call(utils::download.file, args)),
    error = function(e) ivt_offline_abort(url, parent = e, hint = ivt_net_hint(url)))
  if (!identical(as.integer(status), 0L) || !file.exists(destfile))
    ivt_offline_abort(url, hint = ivt_net_hint(url))
  invisible(destfile)
}

# Fetch + parse an HTML page. Through safeconduct when installed (a fresh
# browser per read on a challenging host, retried on a challenge; its
# `page_html()` raises on any HTTP error status left), otherwise
# `xml2::read_html()`. A failure is a `canivt_offline` error.
ivt_fetch_html <- function(url) {
  ivt_require_scrape_pkgs()
  if (ivt_has_safeconduct()) {
    return(tryCatch(safeconduct::page_html(ivt_read_page(url)),
                    error = function(e) ivt_offline_abort(url, parent = e)))
  }
  tryCatch(xml2::read_html(url),
           error = function(e) ivt_offline_abort(url, parent = e,
                                                 hint = ivt_net_hint(url)))
}

# Resolve the URL a page lands on after redirects (the B20/20 viewer behind a
# `URLRedirect.cfm` link). Through safeconduct's `read_page()`, whose `url` is
# the address after redirects; otherwise follow with base R. `NA` when the
# address did not change.
ivt_fetch_final_url <- function(url) {
  if (ivt_has_safeconduct()) {
    resp <- tryCatch(ivt_read_page(url),
                     error = function(e) ivt_offline_abort(url, parent = e))
    final <- resp$url
    if (is.null(final) || identical(final, url)) {
      # a redirect the transport did not follow (the browser route may hand
      # back the first answer): fall back to the Location header
      loc <- resp$headers[["location"]]
      final <- if (is.null(loc)) NA_character_ else loc
    }
    return(final)
  }
  h <- tryCatch(curlGetHeaders(url, verify = TRUE),
                error = function(e) ivt_offline_abort(url, parent = e,
                                                      hint = ivt_net_hint(url)))
  loc <- grep("^[Ll]ocation:", h, value = TRUE)
  if (!length(loc)) return(NA_character_)
  trimws(sub("^[Ll]ocation:", "", loc[length(loc)]))
}

# One page read through safeconduct, as `safeconduct::read_page()` returns it
# (`url`, `status_code`, `headers`, raw `content`). On a challenging host the
# read is retried, each time in a fresh browser, while the host answers with a
# browser check (403) or a rate limit (429), up to `IVT_READ_TRIES` times; the
# last answer is returned whatever it is, so the caller's status handling is
# unchanged. Elsewhere it is a single plain-first read.
IVT_READ_TRIES <- 6L

ivt_read_page <- function(url) {
  tries <- if (ivt_host_needs_browser(url)) IVT_READ_TRIES else 1L
  resp <- NULL
  for (i in seq_len(tries)) {
    resp <- safeconduct::read_page(url, quiet = TRUE)
    if (!isTRUE(resp$status_code %in% c(403L, 429L))) break
    if (i < tries)
      cli::cli_inform("{.val {ivt_url_host(url)}} answered {resp$status_code}; retrying with a fresh browser ({i + 1}/{tries}).")
  }
  resp
}

# The hint attached to a failure on a host known to refuse plain requests, when
# safeconduct is not there to get past the refusal.
ivt_net_hint <- function(url) {
  if (ivt_has_safeconduct() || !ivt_host_needs_browser(url)) return(NULL)
  c(i = paste0("'", ivt_url_host(url), "' refuses requests that do not come ",
               "from a browser. Install the {.pkg safeconduct} package ",
               "({.code pak::pak(\"mountainMath/safeconduct\")}) and canivt ",
               "will fetch through one."))
}

# Hosts observed to answer plain requests with a browser check (2026-11).
IVT_BROWSER_HOSTS <- c("www12.statcan.gc.ca")

ivt_host_needs_browser <- function(url) {
  ivt_url_host(url) %in% IVT_BROWSER_HOSTS
}

ivt_url_host <- function(url) {
  tolower(sub("^[a-z]+://([^/:?#]+).*$", "\\1", url))
}
