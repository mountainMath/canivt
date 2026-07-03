# Member-level context for the tidy/Parquet output: the full member list of
# every labelled column, in codebook member-ordinal order, so collected data can
# be converted into factors whose levels keep even the members that were
# filtered out of the rows.

#' Member levels of an IVT table
#'
#' Returns one row per (column, member) for every labelled column that
#' [ivt_tidy()] emits: each data dimension (with its stored member-ordinal
#' order) and the geography columns. This is the level table [collect_ivt()]
#' uses to convert dimension columns into factors whose levels cover **all**
#' members -- including members filtered out of the data -- and it is written
#' next to the cached Parquet by [ivt_write_parquet()] / [get_statcan_ivt()]
#' (as `<name>_members.parquet`).
#'
#' @param x An `ivt` object from [read_ivt()].
#' @param trim_labels Trim the hierarchy-indentation whitespace from `level`
#'   the same way [ivt_tidy()] does by default (`TRUE`).
#' @return A tibble with columns `column` (the tidy column name), `dimension`
#'   (the full dimension name; `"Geography"` for the geography columns),
#'   `member_id` (1-based StatCan member id), `ordinal` (the codebook
#'   member-ordinal; equals `member_id` when the file stores no ordinal block),
#'   `label` (the stored label, untrimmed), `level` (the label as it appears in
#'   the tidy output) and `depth` (hierarchy depth implied by the label
#'   indentation).
#' @seealso [collect_ivt()]
#' @export
ivt_members <- function(x, trim_labels = TRUE) {
  stopifnot(inherits(x, "ivt"))
  meta <- x$metadata
  fix <- if (trim_labels) trimws else identity
  out <- list()
  # data dimensions: the cells' data columns line up with the non-geography
  # dimensions in declaration order (the same positional match ivt_f2_tidy uses)
  datacols <- setdiff(names(x$cells), c("geo", "value"))
  data_dims <- Filter(function(d) !d$is_geography, meta$dimensions)
  for (j in seq_along(datacols)) {
    if (j > length(data_dims)) break
    d <- data_dims[[j]]
    if (is.null(d$members)) next                 # unlabelled: nothing to level
    ord <- d$ordinal
    if (is.null(ord) || length(ord) != length(d$members))
      ord <- seq_along(d$members)
    out[[length(out) + 1L]] <- tibble::tibble(
      column = datacols[j], dimension = d$name,
      member_id = seq_along(d$members), ordinal = as.integer(ord),
      label = d$members, level = fix(d$members),
      depth = ivt_label_depth(d$members))
  }
  # geography columns, as ivt_tidy emits them (uids are never trimmed there)
  geo <- meta$geographies
  for (col in c("geo_label", "geo_name", "geo_uid", "geo_level")) {
    v <- geo[[col]]
    if (is.null(v)) next
    out[[length(out) + 1L]] <- tibble::tibble(
      column = col, dimension = "Geography",
      member_id = as.integer(seq_along(v)), ordinal = as.integer(seq_along(v)),
      label = v, level = if (col == "geo_uid") v else fix(v),
      depth = ivt_label_depth(v))
  }
  if (!length(out)) return(tibble::tibble(
    column = character(0), dimension = character(0), member_id = integer(0),
    ordinal = integer(0), label = character(0), level = character(0),
    depth = integer(0)))
  do.call(rbind, out)
}

#' Collect IVT data with dimension columns as factors
#'
#' Like `dplyr::collect()`, but converts each labelled dimension column into a
#' factor whose levels are the table's **full** member list in codebook
#' member-ordinal order -- so members filtered out of the collected rows are
#' still visible as factor levels, and members always sort in their StatCan
#' order rather than alphabetically.
#'
#' `x` can be an `ivt` object from [read_ivt()], the Arrow dataset returned by
#' [get_statcan_ivt()] (optionally after `dplyr` verbs such as `filter()`), or
#' a path to a Parquet written by [ivt_write_parquet()]. For the Arrow /
#' Parquet forms the member levels come from the `<name>_members.parquet`
#' sidecar written alongside the data (or pass `members` explicitly, e.g. from
#' [ivt_members()]). Works on both the labelled table and the compact
#' integer-id table (`labels = FALSE`), where the member-id columns are mapped
#' to their labels while being converted.
#'
#' @param x An `ivt` object, an Arrow dataset / dplyr-on-Arrow query, or a
#'   `.parquet` path.
#' @param members A level table from [ivt_members()]; when `NULL` it is located
#'   from `x` (an attached `members` attribute, or the Parquet's
#'   `_members.parquet` sidecar).
#' @param geography Also convert the geography columns (`geo_label`,
#'   `geo_name`, `geo_uid`, `geo_level`) to factors. Default `FALSE`: large
#'   tables carry tens of thousands of geographies, which makes for unwieldy
#'   factor levels.
#' @param ... For `ivt` objects, passed to [ivt_tidy()].
#' @return A tibble with the dimension columns converted to factors.
#' @export
collect_ivt <- function(x, members = NULL, geography = FALSE, ...) {
  if (inherits(x, "ivt")) {
    if (is.null(members)) {
      dots <- list(...)
      trim <- if (is.null(dots$trim_labels)) TRUE else isTRUE(dots$trim_labels)
      members <- ivt_members(x, trim_labels = trim)
    }
    df <- ivt_tidy(x, ...)
  } else if (is.character(x) && length(x) == 1L) {
    if (!requireNamespace("arrow", quietly = TRUE)) {
      cli::cli_abort("Package {.pkg arrow} is required to read Parquet.")
    }
    if (is.null(members)) members <- ivt_read_members(ivt_members_path(x))
    df <- tibble::as_tibble(arrow::read_parquet(x))
  } else {
    if (!requireNamespace("dplyr", quietly = TRUE)) {
      cli::cli_abort("Package {.pkg dplyr} is required to collect Arrow queries.")
    }
    if (is.null(members)) members <- ivt_locate_members(x)
    df <- tibble::as_tibble(dplyr::collect(x))
  }
  if (is.null(members)) {
    cli::cli_abort(c(
      "No member-level table found for {.arg x}.",
      i = "Pass {.arg members} (see {.fn ivt_members}), or re-create the cached
           Parquet (e.g. {.code get_statcan_ivt(..., refresh = TRUE)}) so the
           {.file _members.parquet} sidecar is written."))
  }
  ivt_factorize(df, members, geography = geography)
}

# The sidecar path for a data Parquet: <name>_members.parquet next to it.
ivt_members_path <- function(path) {
  sub("\\.parquet$", "_members.parquet", path, ignore.case = TRUE)
}

# Read a member-level sidecar; NULL when it is absent/unreadable.
ivt_read_members <- function(path) {
  if (!is.character(path) || length(path) != 1L || is.na(path) ||
      !file.exists(path)) return(NULL)
  if (!requireNamespace("arrow", quietly = TRUE)) return(NULL)
  tryCatch(tibble::as_tibble(arrow::read_parquet(path)),
           error = function(e) NULL)
}

# Locate the member-level table for an Arrow dataset / dplyr-on-Arrow query: an
# attached `members` attribute, a `path` attribute pointing at the data Parquet
# (both set by get_statcan_ivt()), walking `$.data` down through query layers to
# the source dataset, whose file list is the last resort.
ivt_locate_members <- function(x) {
  src <- x
  for (i in seq_len(32L)) {
    m <- attr(src, "members", exact = TRUE)
    if (!is.null(m)) return(m)
    p <- attr(src, "path", exact = TRUE)
    if (!is.null(p)) {
      m <- ivt_read_members(ivt_members_path(p))
      if (!is.null(m)) return(m)
    }
    nxt <- tryCatch(src$.data, error = function(e) NULL)
    if (is.null(nxt)) break
    src <- nxt
  }
  files <- tryCatch(src$files, error = function(e) NULL)
  if (is.character(files) && length(files) == 1L) {
    return(ivt_read_members(ivt_members_path(files)))
  }
  NULL
}

# Convert the columns listed in `members` into factors. Levels are the full
# member list in (ordinal, member_id) order; duplicate levels (e.g. identical
# labels at different hierarchy depths after trimming) collapse onto the first.
# Numeric columns are the compact member-id table (`labels = FALSE`) and are
# mapped to their labels while converting; the integer `geo` key has no level
# rows (the geography levels live on geo_label/geo_name/geo_uid/geo_level) and
# is left as is.
ivt_factorize <- function(df, members, geography = FALSE) {
  if (!isTRUE(geography)) {
    members <- members[members$dimension != "Geography", , drop = FALSE]
  }
  for (col in unique(members$column)) {
    if (!col %in% names(df)) next
    m <- members[members$column == col, , drop = FALSE]
    m <- m[order(m$ordinal, m$member_id), , drop = FALSE]
    lvls <- unique(m$level)
    lvls <- lvls[!is.na(lvls)]         # e.g. undecodable geo_name code partials
    orig <- df[[col]]
    v <- if (is.numeric(orig)) m$level[match(orig, m$member_id)] else orig
    f <- factor(v, levels = lvls)
    dropped <- sum(!is.na(orig) & is.na(f))
    if (dropped > 0L) {
      cli::cli_warn(paste(
        "{dropped} value{?s} in column {.field {col}} matched no member level",
        "and became NA (were the data and the member table written with",
        "different {.arg trim_labels}?)."))
    }
    df[[col]] <- f
  }
  df
}
