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

# Is safeconduct installed? Isolated so tests can mock either branch.
ivt_has_safeconduct <- function() {
  requireNamespace("safeconduct", quietly = TRUE)
}

# Download `url` to `destfile`. Through safeconduct when installed and no
# custom `headers` are needed; otherwise `utils::download.file()`. Any failure
# (an error, a non-zero status, a missing file) is a `canivt_offline` error.
#
# Note on `Download.cfm?PID=` (the pre-2021 census tables): as of 2026-11-01
# StatCan's server answers it with a 301 to the datasets index for EVERY
# client, a cleared real browser clicking the link on the product's
# `Alternative.cfm` page included (measured with a logged redirect chain:
# check passed, `Download.cfm?PID=` re-requested with its query intact, 301
# `-> /datasets/Index-eng.cfm`). That is a server-side state, not a transport
# problem; safeconduct reports it as "the server answered with a page, not the
# file" and it surfaces here as `canivt_offline` with that cause attached.
ivt_fetch_file <- function(url, destfile, quiet = FALSE, headers = NULL) {
  if (is.null(headers) && ivt_has_safeconduct()) {
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

# Fetch + parse an HTML page. Through safeconduct when installed (its
# `page_html()` reads with the same plain-first, browser-on-refusal route and
# raises on an HTTP error status), otherwise `xml2::read_html()`. A failure is
# a `canivt_offline` error.
ivt_fetch_html <- function(url) {
  ivt_require_scrape_pkgs()
  if (ivt_has_safeconduct()) {
    return(tryCatch(safeconduct::page_html(url),
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
    resp <- tryCatch(safeconduct::read_page(url, quiet = TRUE),
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
