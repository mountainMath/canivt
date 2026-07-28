# Member-level context for the tidy/Parquet output: the full member list of
# every labelled column, in codebook member-ordinal order, so collected data can
# be converted into factors whose levels keep even the members that were
# filtered out of the rows.

#' Member levels of an IVT table
#'
#' Returns one row per (column, member) for every labelled **data** dimension
#' [ivt_tidy()] emits, in its stored member-ordinal order. This is the level
#' table [collect_ivt()] uses to convert dimension columns into factors whose
#' levels cover **all** members -- including members filtered out of the data --
#' and it is written next to the cached Parquet by [ivt_write_parquet()] /
#' [get_statcan_ivt()] (as `<name>_members.parquet`).
#'
#' The geography columns are **not** levelled. Geography is an identity axis
#' rather than a category: `geo_uid` is the language-neutral key you join on, the
#' member list runs to tens of thousands of entries on the large tables, and its
#' ordinal is a hierarchy traversal rather than an analytic order. Per-member
#' geography context -- names, identifiers, quality flags, and the label
#' hierarchy as `geo_depth`/`geo_parent_id` -- lives in `metadata$geographies`
#' instead.
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
#'   (the full English dimension name),
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
  # Geography is deliberately NOT levelled here. It is an identity axis, not a
  # category: `geo_uid` is the language-neutral join key, the member list runs to
  # tens of thousands on the big tables (it was 99.7% of this table and of the
  # `_members.parquet` sidecar), and its ordinal is a hierarchy traversal rather
  # than the analytic order that makes a data dimension worth factorizing. The
  # per-member geography context lives in `metadata$geographies` -- including the
  # label hierarchy as `geo_depth`/`geo_parent_id`, one row per geography instead
  # of one per geography per geo column.
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
#' The geography columns are left as character: they are identifiers to join on,
#' not categories (see [ivt_members()]). A member table written by an older
#' version that still carries geography rows is accepted, and its geography rows
#' ignored.
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
#' @param dim_names How to name the data-dimension columns: `"slug"` (default,
#'   the terse structural slug the Parquet is written with) or `"label"`, the
#'   full dimension name. For `ivt` objects this is passed to [ivt_tidy()] and
#'   [ivt_members()]; for the Arrow / Parquet forms -- whose columns are named by
#'   how the Parquet was written -- `"label"` applies [label_ivt_columns()] after
#'   the factor conversion, so the result carries both the full labels and the
#'   full member levels.
#' @param language Factor-level language: `"en"` or `"fr"`. `NULL` (default)
#'   auto-detects -- `"en"` for `ivt` objects, and for the Arrow / Parquet forms
#'   the language marker in the file name (see [ivt_parquet_language()]). For
#'   `ivt` objects it is passed to [ivt_tidy()]/[ivt_members()]; for the Arrow /
#'   Parquet forms it selects the French `level_fr` from the sidecar as the factor
#'   levels.
#' @param ... For `ivt` objects, passed to [ivt_tidy()].
#' @return A tibble with the dimension columns converted to factors, carrying
#'   the member table it used as a `members` attribute (and the source Parquet
#'   as `path`) so [label_ivt_columns()] can still be applied afterwards.
#' @examples
#' path <- system.file("extdata", "98100044.ivt", package = "canivt")
#' ivt <- read_ivt(path)
#' df <- collect_ivt(ivt)
#' # data-dimension columns become factors whose levels are the full member list
#' fac <- names(df)[vapply(df, is.factor, logical(1))]
#' head(levels(df[[fac[1]]]))
#' @export
collect_ivt <- function(x, members = NULL,
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
  # An older sidecar may still carry geography rows; drop them once here so the
  # factorizing, the labelling and the attached table all see the same members.
  members <- members[members$dimension != "Geography", , drop = FALSE]
  df <- ivt_factorize(df, members, language = language)
  # On the ivt path the column names came from ivt_tidy(dim_names = ), which has
  # already applied this; the Arrow / Parquet forms are named by however the
  # Parquet was written, so honour it here instead of silently ignoring it.
  # Renaming after factorizing keeps both the labels and the full member levels.
  if (!inherits(x, "ivt") && dim_names == "label")
    df <- label_ivt_columns(df, members = members, language = language)
  # Carry the member table (and the data path it came from) on the result, so
  # label_ivt_columns() and ivt_parquet_language() still work once the data has
  # been collected and the Arrow connection is gone.
  attr(df, "members") <- members
  p <- ivt_data_path(x)
  if (!is.na(p)) attr(df, "path") <- p
  df
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

#' Get the cell-status (missing-cell) table
#'
#' The one accessor for "which of the cells this table does not carry are
#' missing rather than zero, and why", whichever form the table is in: an `ivt`
#' object from [read_ivt(missing = TRUE)][read_ivt], a Parquet path, or the
#' Arrow connection [get_statcan_ivt()] returns.
#'
#' Only cells with a value are stored, so an absent cell is *either* a published
#' zero or a missing value, and this table is the only thing that separates
#' them: every row is an absent cell the file marks as **not** a zero, with the
#' reason the file states (`symbol` / `status`), or `NA` where the page carries
#' only the bare absent mask. Absent cells that appear in neither table are
#' genuine zeros.
#'
#' @param x An `ivt` object, a `.parquet` path, or an Arrow dataset / dplyr query
#'   from [get_statcan_ivt()].
#' @return For an `ivt`, the `missing` tibble (member-id coordinates); for a
#'   Parquet source, a lazy [arrow::open_dataset()] connection to the
#'   `_missing.parquet` sidecar with the same labelled coordinates as the data.
#'   `NULL` when the table carries none -- i.e. it was decoded without
#'   `missing = TRUE`.
#' @seealso [read_ivt()], [ivt_tidy_missing()], [ivt_write_parquet()]
#' @examples
#' path <- system.file("extdata", "98100044.ivt", package = "canivt")
#' ivt_missing(read_ivt(path, missing = TRUE))
#' @export
ivt_missing <- function(x) {
  if (inherits(x, "ivt")) return(x$missing)
  src <- x
  for (i in seq_len(32L)) {
    m <- attr(src, "missing", exact = TRUE)
    if (!is.null(m)) return(m)
    p <- ivt_data_path(src)
    if (!is.na(p)) {
      mp <- ivt_missing_path(p)
      if (file.exists(mp) && requireNamespace("arrow", quietly = TRUE))
        return(tryCatch(arrow::open_dataset(mp), error = function(e) NULL))
    }
    if (is.data.frame(src)) return(NULL)     # no query layers to walk
    nxt <- tryCatch(src$.data, error = function(e) NULL)
    if (is.null(nxt)) break
    src <- nxt
  }
  NULL
}

# The cell-status sidecar path for a data Parquet: <name>_missing.parquet next
# to it. Unlike the member sidecar this KEEPS the language marker
# (`<key>_en_missing.parquet`), because the table is labelled like the data it
# accompanies -- one file per language, not one shared by both.
ivt_missing_path <- function(path) {
  paste0(sub("\\.parquet$", "", path, ignore.case = TRUE), "_missing.parquet")
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
    # a data frame has no query layers to walk, and `$files` on a tibble warns
    if (is.data.frame(src)) break
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
    if (is.data.frame(src)) return(NULL)   # no query layers to walk
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
#' It can be called either side of [collect_ivt()]: before, on the connection
#' (nothing is read until the collect), or after, on the collected data frame --
#' which carries the member table it used as an attribute. Either order gives
#' the same labelled, fully-levelled result, and `collect_ivt(dim_names =
#' "label")` is the one-call shorthand for it.
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
  out <- dplyr::rename(x, !!!nv)
  # keep the lookup attributes collect_ivt attached, so the labelled result is
  # no less self-describing than the one it was made from
  if (is.data.frame(out)) {
    for (a in c("members", "path")) {
      v <- attr(x, a, exact = TRUE)
      if (!is.null(v) && is.null(attr(out, a, exact = TRUE))) attr(out, a) <- v
    }
  }
  out
}

# Column names of x (Arrow dataset / query / data frame), or character(0).
ivt_colnames <- function(x) {
  n <- tryCatch(names(x), error = function(e) NULL)
  if (is.null(n)) n <- tryCatch(colnames(x), error = function(e) NULL)
  if (is.null(n)) character(0) else n
}

# Map each member-table `column` onto the column that actually carries it in
# `cols`. The member table records the name the data was written with (the
# structural slug, or the full label when written with `dim_names = "label"`),
# so that is the primary key. But a table that has been through
# label_ivt_columns() carries the full dimension label instead -- and the member
# table records that too, in `dimension`/`dimension_fr`, which makes the mapping
# recoverable from the metadata rather than from the column name alone. Label
# matches only claim columns no slug matched, so a dimension whose label happens
# to equal another dimension's slug cannot steal it. Unmatched entries map to NA.
ivt_member_col_map <- function(members, cols, language = "en") {
  slugs <- unique(members$column)
  out <- stats::setNames(rep(NA_character_, length(slugs)), slugs)
  if (!length(slugs)) return(out)
  first <- match(slugs, members$column)
  dimen <- members$dimension[first]
  dimfr <- if ("dimension_fr" %in% names(members)) members$dimension_fr[first]
           else rep(NA_character_, length(slugs))
  # pass 1: the name the data was written with
  hit <- slugs %in% cols
  out[hit] <- slugs[hit]
  # pass 2: the full dimension label, in the same make.unique() form
  # label_ivt_columns() writes it (uniquified over the data columns only, in
  # member-table order), then the bare EN/FR names as a last resort
  is_geo <- dimen == "Geography"
  lab <- if (language == "fr")
    ifelse(!is.na(dimfr) & nzchar(dimfr), dimfr, dimen) else dimen
  uni <- rep(NA_character_, length(slugs))
  d <- which(!is_geo)
  if (length(d)) uni[d] <- make.unique(lab[d])
  for (i in which(!hit & !is_geo)) {
    cand <- unique(c(uni[i], lab[i], dimen[i], dimfr[i]))
    cand <- cand[!is.na(cand) & nzchar(cand) & cand %in% cols & !cand %in% out]
    if (length(cand)) out[i] <- cand[1L]
  }
  out
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
ivt_factorize <- function(df, members, language = "en") {
  # Geography is never levelled (see ivt_members()). The filter stays because a
  # `_members.parquet` written by an older version still carries geography rows,
  # and an existing cache must not start factorizing `geo_uid` behind the user.
  members <- members[members$dimension != "Geography", , drop = FALSE]
  has_fr <- language == "fr" && "level_fr" %in% names(members)
  colmap <- ivt_member_col_map(members, names(df), language = language)
  for (col in unique(members$column)) {
    target <- colmap[[col]]
    if (is.na(target)) next
    m <- members[members$column == col, , drop = FALSE]
    m <- m[order(m$ordinal, m$member_id), , drop = FALSE]
    lev <- if (has_fr && !all(is.na(m$level_fr))) m$level_fr else m$level
    lvls <- unique(lev)
    lvls <- lvls[!is.na(lvls)]         # e.g. undecodable geo_name code partials
    orig <- df[[target]]
    v <- if (is.numeric(orig)) lev[match(orig, m$member_id)] else orig
    f <- factor(v, levels = lvls)
    dropped <- sum(!is.na(orig) & is.na(f))
    if (dropped > 0L) {
      cli::cli_warn(paste(
        "{dropped} value{?s} in column {.field {target}} matched no member level",
        "and became NA (were the data and the member table written with",
        "different {.arg trim_labels}?)."))
    }
    df[[target]] <- f
  }
  df
}
