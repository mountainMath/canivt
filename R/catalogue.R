# Catalogue of StatCan Beyond 20/20 IVT products, scraped from the public
# census datasets index (https://www12.statcan.gc.ca/datasets/). Each census
# "Temporal" version is one Index page that lists every product in a table; the
# IVT download link is either a direct b2020 `.zip` (2021 era) or an
# `Alternative.cfm?PID=` intermediate page (older eras) that forwards to a
# `Download.cfm?PID=` raw `.ivt`.

STATCAN_DATASETS_BASE <- "https://www12.statcan.gc.ca/datasets/"

# Age (days) beyond which the cached catalogue is considered out of date.
IVT_CATALOGUE_MAX_AGE_DAYS <- 30

# Per-session state (e.g. "stale-catalogue warning already shown").
.ivt_session <- new.env(parent = emptyenv())

#' Available census versions on the StatCan datasets index
#'
#' Reads the `Temporal` selector from the StatCan census datasets index page,
#' i.e. the list of census versions whose IVT products can be catalogued with
#' [statcan_ivt_catalogue()].
#'
#' @return A tibble with one row per version: `temporal` (the URL parameter,
#'   e.g. `"2017"` for the 2016 long-form), `census` (the human label, e.g.
#'   `"2016 Census - Part B (long-form questionnaire)"`) and `census_year` (the
#'   leading 4-digit year of the label as an integer).
#' @export
statcan_ivt_years <- function() {
  doc <- ivt_read_html(paste0(STATCAN_DATASETS_BASE, "Index-eng.cfm?Temporal=2021"))
  opts <- rvest::html_elements(doc, "select#Temporal option")
  if (!length(opts)) cli::cli_abort("Could not find the Temporal selector on the StatCan index page.")
  label <- trimws(rvest::html_text2(opts))
  tibble::tibble(
    temporal    = rvest::html_attr(opts, "value"),
    census      = label,
    census_year = as.integer(sub("^(\\d{4}).*", "\\1", label))
  )
}

#' Catalogue of StatCan Beyond 20/20 IVT products
#'
#' Scrapes the StatCan census datasets index into a tidy catalogue of every IVT
#' product: census year, catalogue number, release date, topic, title and the
#' download URLs. The full catalogue (all census versions) is cached as a
#' Parquet file in the data cache ([ivt_cache_dir("data")][ivt_cache_dir]) so it
#' is scraped only once; pass `refresh = TRUE` to rebuild it. When the cached
#' catalogue is a month or more old a warning (once per session) suggests
#' refreshing it.
#'
#' @param temporal Optional character/numeric vector of census versions to
#'   return (the `temporal` values from [statcan_ivt_years()], e.g. `2001` or
#'   `c(2021, 2016)`). When `NULL` (default) the whole catalogue is returned.
#'   Filtering does not avoid building the full cache the first time.
#' @param refresh Re-scrape the index even if a cached catalogue exists.
#' @param quiet Suppress per-page progress messages.
#' @return A tibble with columns `census_year`, `temporal`, `catalogue`,
#'   `archived`, `release_date`, `date`, `topic`, `title`, `pid`, `ivt_url`,
#'   `download_url` and `http_url`. `ivt_url` is the link as published (the
#'   `Alternative.cfm` intermediate page or a direct b2020 `.zip`);
#'   `download_url` is the resolved direct-download URL (see
#'   [statcan_ivt_resolve_url()]).
#' @export
statcan_ivt_catalogue <- function(temporal = NULL, refresh = FALSE, quiet = FALSE) {
  ivt_require_scrape_pkgs()
  cache_file <- file.path(ivt_cache_dir("data"), "statcan_ivt_catalogue.parquet")

  if (!refresh && file.exists(cache_file) &&
      requireNamespace("arrow", quietly = TRUE)) {
    catl <- tibble::as_tibble(arrow::read_parquet(cache_file))
    ivt_warn_stale_catalogue(cache_file)
  } else {
    years <- statcan_ivt_years()
    parts <- lapply(seq_len(nrow(years)), function(i) {
      if (!quiet) cli::cli_inform("Scraping {years$census[i]} ({years$temporal[i]})")
      ivt_scrape_index(years$temporal[i], years$census_year[i])
    })
    catl <- tibble::as_tibble(do.call(rbind, parts))
    if (requireNamespace("arrow", quietly = TRUE)) {
      arrow::write_parquet(catl, cache_file)
    }
  }

  if (!is.null(temporal)) {
    catl <- catl[catl$temporal %in% as.character(temporal), , drop = FALSE]
  }
  catl
}

# Warn (once per session, per source) when a cached catalogue is a month or more
# old. `label` names the source and `refresh_call` the code that rebuilds it;
# `flag` is the per-source session slot so each catalogue warns independently.
ivt_warn_stale_catalogue <- function(cache_file, label = "StatCan",
                                     refresh_call = "statcan_ivt_catalogue(refresh = TRUE)",
                                     flag = "catalogue_stale_warned") {
  if (isTRUE(.ivt_session[[flag]])) return(invisible())
  age <- as.numeric(difftime(Sys.time(), file.mtime(cache_file), units = "days"))
  if (is.na(age) || age < IVT_CATALOGUE_MAX_AGE_DAYS) return(invisible())
  .ivt_session[[flag]] <- TRUE
  cli::cli_warn(c(
    "The cached {label} IVT catalogue is {round(age)} days old.",
    i = "Call {.code {refresh_call}} to rebuild it from the live index."
  ))
  invisible()
}

# Scrape one census version's Index page into catalogue rows.
ivt_scrape_index <- function(temporal, census_year = NA_integer_) {
  url <- sprintf("%sIndex-eng.cfm?Temporal=%s", STATCAN_DATASETS_BASE, temporal)
  doc <- ivt_read_html(url)
  rows <- rvest::html_elements(doc, "table.wb-tables tbody tr")
  if (!length(rows)) return(NULL)

  parts <- lapply(rows, ivt_parse_index_row)
  out <- do.call(rbind, parts)
  if (is.null(out)) return(NULL)
  out$temporal <- as.character(temporal)
  out$census_year <- census_year
  out[c("census_year", "temporal", "catalogue", "archived", "release_date",
        "date", "topic", "title", "pid", "ivt_url", "download_url", "http_url")]
}

# Parse a single product <tr> into a one-row data frame; NULL if it has no IVT.
ivt_parse_index_row <- function(r) {
  td_ivt <- rvest::html_element(r, "td:nth-child(4) a[title*='IVT']")
  ivt_href <- rvest::html_attr(td_ivt, "href")
  if (is.na(ivt_href)) return(NULL)

  th <- rvest::html_element(r, "th")
  catalogue <- trimws(xml2::xml_text(xml2::xml_find_first(th, "./text()")))
  archived <- length(rvest::html_elements(th, "span.label-warning")) > 0L

  td_date <- rvest::html_element(r, "td:nth-child(2)")
  date_disp <- trimws(rvest::html_text2(td_date))
  date_sort <- rvest::html_attr(td_date, "data-sort")
  release_date <- as.Date(date_sort, format = "%Y%m%d")

  topic <- trimws(rvest::html_text2(rvest::html_element(r, "td:nth-child(3)")))

  td_title <- rvest::html_element(r, "td:nth-child(4)")
  title <- trimws(xml2::xml_text(xml2::xml_find_first(td_title, "./text()")))
  http_href <- rvest::html_attr(
    rvest::html_element(td_title, "a[title*='HTML']"), "href")

  ivt_url <- ivt_abs_url(ivt_href)
  data.frame(
    catalogue    = catalogue,
    archived     = archived,
    release_date = release_date,
    date         = date_disp,
    topic        = topic,
    title        = title,
    pid          = ivt_extract_pid(ivt_href),
    ivt_url      = ivt_url,
    download_url = statcan_ivt_resolve_url(ivt_url),
    http_url     = ivt_abs_url(http_href),
    stringsAsFactors = FALSE
  )
}

#' Resolve a published IVT link to its direct-download URL
#'
#' StatCan publishes the IVT link in two forms. The 2021-era products link
#' straight to a Beyond 20/20 `.zip`; older products link to an
#' `Alternative.cfm?PID=` landing page that itself forwards to a
#' `Download.cfm?PID=` endpoint serving the raw `.ivt`. This returns the direct
#' URL in either case (a `.zip` is returned unchanged).
#'
#' @param ivt_url The published IVT link (absolute or relative to the datasets
#'   base).
#' @return The direct-download URL.
#' @export
statcan_ivt_resolve_url <- function(ivt_url) {
  out <- ivt_abs_url(ivt_url)
  alt <- grepl("Alternative\\.cfm", out, ignore.case = TRUE)
  pid <- ivt_extract_pid(out)
  out[alt] <- sprintf("%sDownload.cfm?PID=%s", STATCAN_DATASETS_BASE, pid[alt])
  out
}

# Pull the numeric PID out of an Alternative/Download.cfm URL (NA otherwise).
ivt_extract_pid <- function(url) {
  pid <- sub(".*[?&][Pp][Ii][Dd]=([0-9]+).*", "\\1", url)
  ifelse(grepl("[Pp][Ii][Dd]=[0-9]+", url), pid, NA_character_)
}

# Resolve a possibly-relative datasets href to an absolute URL.
ivt_abs_url <- function(href) {
  out <- href
  rel <- !is.na(href) & !grepl("^https?://", href)
  # Leading-slash paths are site-absolute; others are relative to /datasets/.
  root <- sub("^(https?://[^/]+).*", "\\1", STATCAN_DATASETS_BASE)
  out[rel & startsWith(href[rel], "/")] <-
    paste0(root, href[rel & startsWith(href[rel], "/")])
  out[rel & !startsWith(href[rel], "/")] <-
    paste0(STATCAN_DATASETS_BASE, href[rel & !startsWith(href[rel], "/")])
  out
}

# Fetch + parse an HTML page (xml2/rvest). Isolated for testability.
ivt_read_html <- function(url) {
  ivt_require_scrape_pkgs()
  xml2::read_html(url)
}

ivt_require_scrape_pkgs <- function() {
  for (p in c("rvest", "xml2")) {
    if (!requireNamespace(p, quietly = TRUE)) {
      cli::cli_abort("Package {.pkg {p}} is required to scrape the StatCan catalogue.")
    }
  }
}
