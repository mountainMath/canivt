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
#' @param dim_names How the data-dimension `column` names are formed, matching
#'   [ivt_tidy()]: `"slug"` (default, the terse structural slug) or `"label"` (the
#'   full dimension name). Must match the tidy output the levels will be joined
#'   to.
#' @param language Language for the `column` names (label mode), matching
#'   [ivt_tidy()]: `"en"` (default) or `"fr"`. The table always carries both the
#'   English `level` and the French `level_fr`, so a single sidecar serves both
#'   languages; only the label-derived `column` names follow `language`.
#' @return A tibble with columns `column` (the tidy column name), `dimension`
#'   (the full English dimension name; `"Geography"` for the geography columns),
#'   `dimension_fr` (the French dimension name, `NA` when none -- used by
#'   [label_ivt_columns()]), `member_id` (1-based StatCan member id), `ordinal`
#'   (the codebook
#'   member-ordinal; equals `member_id` when the file stores no ordinal block),
#'   `label` (the stored label, untrimmed), `level` (the label as it appears in
#'   the tidy output), `level_fr` (the French label, `NA` when the file carries
#'   none for that column), `depth` (hierarchy depth implied by the label
#'   indentation), `parent_id` (the `member_id` of this member's parent in
#'   that hierarchy -- the nearest preceding member at a shallower depth, `NA`
#'   for top-level members), and `description`/`description_fr` (the member's
#'   `_Description` prose -- the indicator definition carried by the facet /
#'   quantity dimension of the older survey tables, e.g. a total fertility rate's
#'   "... the number of children born per 1,000 women ...", which states the
#'   value's units; `NA` for the many dimensions/tables that carry none).
#' @seealso [collect_ivt()]
#' @examples
#' path <- system.file("extdata", "98100044.ivt", package = "canivt")
#' ivt <- read_ivt(path)
#' ivt_members(ivt)
#' @export
ivt_members <- function(x, trim_labels = TRUE, dim_names = c("slug", "label"),
                        language = "en") {
  stopifnot(inherits(x, "ivt"))
  dim_names <- match.arg(dim_names)
  language <- ivt_norm_lang(language)
  meta <- x$metadata
  fix <- if (trim_labels) trimws else identity
  out <- list()
  # data dimensions: the cells' data columns line up with the non-geography
  # dimensions in declaration order (the same positional match ivt_f2_tidy uses)
  datacols <- setdiff(names(x$cells), c("geo", "value"))
  colnm <- ivt_data_colnames(datacols, meta, dim_names, language)
  data_dims <- Filter(function(d) !d$is_geography, meta$dimensions)
  # French level, aligned to the English member vector `v` (NA when unavailable)
  fr_level <- function(v, fr) {
    if (is.null(fr) || length(fr) != length(v)) rep(NA_character_, length(v))
    else fix(fr)
  }
  # per-member description text (the `_Description` indicator definition), aligned to
  # `v`; NA when the dimension carries none (so most columns/tables get an all-NA
  # column that leaves existing outputs unchanged)
  desc_col <- function(v, desc) {
    if (is.null(desc) || length(desc) != length(v)) rep(NA_character_, length(v))
    else desc
  }
  for (j in seq_along(datacols)) {
    if (j > length(data_dims)) break
    d <- data_dims[[j]]
    if (is.null(d$members)) next                 # unlabelled: nothing to level
    ord <- d$ordinal
    if (is.null(ord) || length(ord) != length(d$members))
      ord <- seq_along(d$members)
    out[[length(out) + 1L]] <- tibble::tibble(
      column = colnm[j], dimension = d$name,
      dimension_fr = if (is.null(d$name_fr)) NA_character_ else d$name_fr,
      member_id = seq_along(d$members), ordinal = as.integer(ord),
      label = d$members, level = fix(d$members),
      level_fr = fr_level(d$members, d$members_fr),
      depth = ivt_label_depth(d$members),
      parent_id = ivt_label_parent(d$members),
      description = desc_col(d$members, d$description),
      description_fr = desc_col(d$members, d$description_fr))
  }
  # geography columns, as ivt_tidy emits them (uids are never trimmed there)
  geo <- meta$geographies
  geo_fr <- c(geo_label = "geo_label_fr", geo_name = "geo_name_fr")
  for (col in c("geo_label", "geo_name", "geo_uid", "geo_level")) {
    v <- geo[[col]]
    if (is.null(v)) next
    out[[length(out) + 1L]] <- tibble::tibble(
      column = col, dimension = "Geography", dimension_fr = NA_character_,
      member_id = as.integer(seq_along(v)), ordinal = as.integer(seq_along(v)),
      label = v, level = if (col == "geo_uid") v else fix(v),
      level_fr = if (col %in% names(geo_fr)) fr_level(v, geo[[geo_fr[[col]]]])
                 else rep(NA_character_, length(v)),
      depth = ivt_label_depth(v), parent_id = ivt_label_parent(v),
      description = rep(NA_character_, length(v)),
      description_fr = rep(NA_character_, length(v)))
  }
  if (!length(out)) return(tibble::tibble(
    column = character(0), dimension = character(0), dimension_fr = character(0),
    member_id = integer(0), ordinal = integer(0), label = character(0),
    level = character(0), level_fr = character(0), depth = integer(0),
    parent_id = integer(0), description = character(0),
    description_fr = character(0)))
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
#' @param dim_names For `ivt` objects, how to name the data-dimension columns
#'   (passed to [ivt_tidy()] and [ivt_members()]): `"slug"` (default) or
#'   `"label"`. Ignored for the Arrow / Parquet forms, where the column names are
#'   already fixed by how the Parquet was written.
#' @param language Factor-level language: `"en"` or `"fr"`. `NULL` (default)
#'   auto-detects -- `"en"` for `ivt` objects, and for the Arrow / Parquet forms
#'   the language marker in the file name (see [ivt_parquet_language()]). For
#'   `ivt` objects it is passed to [ivt_tidy()]/[ivt_members()]; for the Arrow /
#'   Parquet forms it selects the French `level_fr` from the sidecar as the factor
#'   levels.
#' @param ... For `ivt` objects, passed to [ivt_tidy()].
#' @return A tibble with the dimension columns converted to factors.
#' @examples
#' path <- system.file("extdata", "98100044.ivt", package = "canivt")
#' ivt <- read_ivt(path)
#' df <- collect_ivt(ivt)
#' # data-dimension columns become factors whose levels are the full member list
#' fac <- names(df)[vapply(df, is.factor, logical(1))]
#' head(levels(df[[fac[1]]]))
#' @export
collect_ivt <- function(x, members = NULL, geography = FALSE,
                        dim_names = c("slug", "label"), language = NULL, ...) {
  dim_names <- match.arg(dim_names)
  # auto-detect the language: "en" for ivt objects, else the file-name marker.
  if (is.null(language))
    language <- if (inherits(x, "ivt")) "en" else ivt_parquet_language(x)
  language <- ivt_norm_lang(language)
  if (inherits(x, "ivt")) {
    if (is.null(members)) {
      dots <- list(...)
      trim <- if (is.null(dots$trim_labels)) TRUE else isTRUE(dots$trim_labels)
      members <- ivt_members(x, trim_labels = trim, dim_names = dim_names,
                             language = language)
    }
    df <- ivt_tidy(x, dim_names = dim_names, language = language, ...)
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
  ivt_factorize(df, members, geography = geography, language = language)
}

# The sidecar path for a data Parquet: <name>_members.parquet next to it. A
# trailing language marker (`_en`/`_fr`) is stripped first, so the English and
# French Parquets of one table (`<key>_en.parquet` / `<key>_fr.parquet`) share a
# single language-neutral sidecar (it carries both `level` and `level_fr`).
ivt_members_path <- function(path) {
  stem <- sub("\\.parquet$", "", path, ignore.case = TRUE)
  stem <- sub("_(en|fr)$", "", stem, ignore.case = TRUE)
  paste0(stem, "_members.parquet")
}

#' Detect the language of an IVT Parquet
#'
#' Reads the language marker (`_en` / `_fr` before `.parquet`) that
#' [ivt_write_parquet()] / [get_statcan_ivt()] put in the file name, so
#' [collect_ivt()] and [label_ivt_columns()] can pick the matching language
#' without being told. Falls back to `"en"` when there is no marker.
#'
#' @param x A `.parquet` path, an Arrow dataset, or a dplyr-on-Arrow query (the
#'   path is taken from the `path` attribute / source file list).
#' @return `"en"` or `"fr"`.
#' @examples
#' ivt_parquet_language("98-10-0044_fr.parquet")
#' ivt_parquet_language("98-10-0044_en.parquet")
#' @export
ivt_parquet_language <- function(x) {
  path <- ivt_data_path(x)
  if (is.na(path)) return("en")
  fn <- basename(path)
  if (grepl("_fr\\.parquet$", fn, ignore.case = TRUE)) return("fr")
  "en"
}

# Best-effort data-file path for x: the string itself when a path, else the
# `path` attribute (set by get_statcan_ivt()) or the source dataset's single
# file, walking `$.data` down a dplyr-on-Arrow query. NA when none is found.
ivt_data_path <- function(x) {
  if (is.character(x) && length(x) == 1L && !is.na(x)) return(x)
  src <- x
  for (i in seq_len(32L)) {
    p <- attr(src, "path", exact = TRUE)
    if (is.character(p) && length(p) == 1L) return(p)
    files <- tryCatch(src$files, error = function(e) NULL)
    if (is.character(files) && length(files) == 1L) return(files)
    nxt <- tryCatch(src$.data, error = function(e) NULL)
    if (is.null(nxt)) break
    src <- nxt
  }
  NA_character_
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

#' Relabel slug data columns with their full dimension names
#'
#' The Parquet written by [ivt_write_parquet()] / [get_statcan_ivt()] names its
#' data-dimension columns by their compact structural slug (`age`, `tenure`, ...).
#' This renames those columns to the full dimension label -- English or French --
#' on an Arrow dataset / dplyr-on-Arrow query (lazily, no data read) or a
#' collected data frame. Geography columns (`geo_name`, `geo_uid`, ...) are left as
#' is; a column whose slug is not found is skipped.
#'
#' The slug -> label map comes from the `<name>_members.parquet` sidecar (or an
#' explicit `members` table, e.g. from [ivt_members()]). The language is taken
#' from the file name marker via [ivt_parquet_language()] unless given, so the
#' labels match the language the Parquet was written in.
#'
#' @param x An Arrow dataset, a dplyr-on-Arrow query, or a data frame.
#' @param members A level table from [ivt_members()]; when `NULL` it is located
#'   from `x` (attached `members` attribute or the `_members.parquet` sidecar).
#' @param language `"en"` or `"fr"`; `NULL` (default) auto-detects from the file
#'   name (see [ivt_parquet_language()]).
#' @return `x` with its data-dimension columns renamed (an Arrow query when `x`
#'   is an Arrow object, else a data frame).
#' @seealso [collect_ivt()], [ivt_parquet_language()]
#' @examples
#' path <- system.file("extdata", "98100044.ivt", package = "canivt")
#' ivt <- read_ivt(path)
#' if (requireNamespace("dplyr", quietly = TRUE)) {
#'   df <- ivt_tidy(ivt, labels = FALSE)          # slug-named columns
#'   labelled <- label_ivt_columns(df, members = ivt_members(ivt))
#'   names(labelled)
#' }
#' @export
label_ivt_columns <- function(x, members = NULL, language = NULL) {
  if (!requireNamespace("dplyr", quietly = TRUE)) {
    cli::cli_abort("Package {.pkg dplyr} is required to rename columns.")
  }
  if (is.null(language)) language <- ivt_parquet_language(x)
  language <- ivt_norm_lang(language)
  if (is.null(members)) {
    members <- if (is.character(x) && length(x) == 1L)
      ivt_read_members(ivt_members_path(x)) else ivt_locate_members(x)
  }
  if (is.null(members)) {
    cli::cli_abort(c(
      "No member-level table found for {.arg x}.",
      i = "Pass {.arg members} (see {.fn ivt_members}), or write the Parquet with
           its {.file _members.parquet} sidecar (the default)."))
  }
  # slug -> full label, one row per data-dimension column
  md <- members[members$dimension != "Geography" & !is.na(members$column), ,
                drop = FALSE]
  md <- md[!duplicated(md$column), , drop = FALSE]
  lab <- if (language == "fr" && "dimension_fr" %in% names(md))
    ifelse(!is.na(md$dimension_fr) & nzchar(md$dimension_fr),
           md$dimension_fr, md$dimension)
  else md$dimension
  cols <- ivt_colnames(x)
  keep <- md$column %in% cols & md$column != lab & !is.na(lab) & nzchar(lab)
  if (!any(keep)) return(x)
  nv <- stats::setNames(md$column[keep], make.unique(lab[keep]))   # new = old
  dplyr::rename(x, !!!nv)
}

# Column names of x (Arrow dataset / query / data frame), or character(0).
ivt_colnames <- function(x) {
  n <- tryCatch(names(x), error = function(e) NULL)
  if (is.null(n)) n <- tryCatch(colnames(x), error = function(e) NULL)
  if (is.null(n)) character(0) else n
}

# Convert the columns listed in `members` into factors. Levels are the full
# member list in (ordinal, member_id) order; duplicate levels (e.g. identical
# labels at different hierarchy depths after trimming) collapse onto the first.
# Numeric columns are the compact member-id table (`labels = FALSE`) and are
# mapped to their labels while converting; the integer `geo` key has no level
# rows (the geography levels live on geo_label/geo_name/geo_uid/geo_level) and
# is left as is. `language = "fr"` uses the French `level_fr` where the column
# has one (per column, so a column with no French copy -- which the tidy output
# also left English -- keeps its English levels).
ivt_factorize <- function(df, members, geography = FALSE, language = "en") {
  if (!isTRUE(geography)) {
    members <- members[members$dimension != "Geography", , drop = FALSE]
  }
  has_fr <- language == "fr" && "level_fr" %in% names(members)
  for (col in unique(members$column)) {
    if (!col %in% names(df)) next
    m <- members[members$column == col, , drop = FALSE]
    m <- m[order(m$ordinal, m$member_id), , drop = FALSE]
    lev <- if (has_fr && !all(is.na(m$level_fr))) m$level_fr else m$level
    lvls <- unique(lev)
    lvls <- lvls[!is.na(lvls)]         # e.g. undecodable geo_name code partials
    orig <- df[[col]]
    v <- if (is.numeric(orig)) lev[match(orig, m$member_id)] else orig
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
