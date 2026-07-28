#' Write an IVT table to Parquet
#'
#' @param x An `ivt` object from [read_ivt()].
#' @param path Output `.parquet` path. Defaults to `<product_id>.parquet` in the
#'   data cache ([ivt_cache_dir("data")][ivt_cache_dir], i.e. option
#'   `canivt.data_cache` or [tempdir()] when unset).
#' @param labels Passed to [ivt_tidy()]: write labelled columns (`TRUE`,
#'   default) or the compact integer-id table (`FALSE`).
#' @param members Also write the member-level table ([ivt_members()]) as a
#'   `<name>_members.parquet` sidecar next to `path` (`TRUE`, default), so
#'   [collect_ivt()] can convert dimension columns to full-level factors.
#' @param missing Also write the cell-status table ([ivt_tidy_missing()]) as a
#'   `<name>_missing.parquet` sidecar next to `path` (`TRUE`, default), when `x`
#'   carries one -- i.e. when it was read with `read_ivt(missing = TRUE)`. The
#'   data table holds only the cells that have a value; this sidecar is what
#'   says of the rest which are genuine zeros (absent from both) and which are
#'   missing, and why. Its coordinate columns are labelled exactly like the data
#'   table's, so the two join. Silently skipped when `x$missing` is `NULL`.
#' @param dim_names How to name the data-dimension columns (passed to
#'   [ivt_tidy()] and the member sidecar): `"slug"` (default, the terse
#'   structural slug) or `"label"` (the full dimension name). Slug columns can be
#'   labelled on read with [label_ivt_columns()].
#' @param language Output language for labels and label-derived column names
#'   (passed to [ivt_tidy()]): `"en"` (default) or `"fr"`. The member sidecar
#'   carries both languages regardless.
#' @param ... Passed to [arrow::write_parquet()].
#' @return `path`, invisibly.
#' @examples
#' path <- system.file("extdata", "98100044.ivt", package = "canivt")
#' ivt <- read_ivt(path)
#' if (requireNamespace("arrow", quietly = TRUE)) {
#'   out <- ivt_write_parquet(ivt, file.path(tempdir(), "98100044.parquet"))
#'   file.exists(out)
#' }
#' @export
ivt_write_parquet <- function(x, path = NULL, labels = TRUE, members = TRUE,
                              missing = TRUE, dim_names = c("slug", "label"),
                              language = "en", ...) {
  if (!requireNamespace("arrow", quietly = TRUE)) {
    cli::cli_abort("Package {.pkg arrow} is required to write Parquet.")
  }
  dim_names <- match.arg(dim_names)
  language <- ivt_norm_lang(language)
  # the default cache path carries the language marker so the English and French
  # Parquets of one table coexist (`<pid>_en.parquet` / `<pid>_fr.parquet`).
  if (is.null(path)) path <- ivt_data_cache_file(x, paste0("_", language, ".parquet"))
  arrow::write_parquet(
    ivt_tidy(x, labels = labels, dim_names = dim_names, language = language),
    path, ...)
  if (isTRUE(members)) {
    mem <- ivt_members(x, dim_names = dim_names, language = language)
    if (nrow(mem)) arrow::write_parquet(mem, ivt_members_path(path))
  }
  if (isTRUE(missing) && !is.null(x$missing)) {
    arrow::write_parquet(
      ivt_tidy_missing(x, labels = labels, dim_names = dim_names,
                       language = language),
      ivt_missing_path(path))
  }
  invisible(path)
}

#' Write an IVT table to CSV
#'
#' @inheritParams ivt_write_parquet
#' @param path Output `.csv` path. Defaults to `<product_id>.csv` in the data
#'   cache ([ivt_cache_dir("data")][ivt_cache_dir]).
#' @param missing Also write the cell-status table ([ivt_tidy_missing()]) to a
#'   `<name>_missing.csv` next to `path` (`TRUE`, default), when `x` carries one
#'   (i.e. was read with `read_ivt(missing = TRUE)`). Silently skipped
#'   otherwise.
#' @param ... Passed to the CSV writer ([readr::write_csv()] if available, else
#'   [utils::write.csv()]).
#' @return `path`, invisibly.
#' @examples
#' path <- system.file("extdata", "98100044.ivt", package = "canivt")
#' ivt <- read_ivt(path)
#' out <- ivt_write_csv(ivt, file.path(tempdir(), "98100044.csv"))
#' file.exists(out)
#' @export
ivt_write_csv <- function(x, path = NULL, labels = TRUE, missing = TRUE,
                          dim_names = c("slug", "label"), language = "en", ...) {
  dim_names <- match.arg(dim_names)
  language <- ivt_norm_lang(language)
  if (is.null(path)) path <- ivt_data_cache_file(x, paste0("_", language, ".csv"))
  wr <- function(df, p) {
    if (requireNamespace("readr", quietly = TRUE)) readr::write_csv(df, p, ...)
    else utils::write.csv(df, p, row.names = FALSE, ...)
  }
  wr(ivt_tidy(x, labels = labels, dim_names = dim_names, language = language),
     path)
  if (isTRUE(missing) && !is.null(x$missing)) {
    wr(ivt_tidy_missing(x, labels = labels, dim_names = dim_names,
                        language = language),
       paste0(sub("\\.csv$", "", path, ignore.case = TRUE), "_missing.csv"))
  }
  invisible(path)
}

#' Write the table metadata (codebook + footnotes) to disk
#'
#' Emits the parts of an IVT that are not the data table itself, as a set of
#' CSV files in `dir`: the dimension members (`dimension_members.csv`), the
#' geography table (`geographies.csv` -- bilingual labels/names, uid, and
#' whatever attributes the vintage stores: aggregation level, geography type /
#' municipal status, data-quality flag + note, total non-response rate),
#' the footnotes (`footnotes.csv`), the data-quality-flag legend
#' (`dqf_legend.csv`, when the table carries one) and the table identity
#' (`table_info.csv`).
#'
#' @param x An `ivt` object or a metadata list from [ivt_metadata()].
#' @param dir Output directory (created if needed). Defaults to
#'   `<product_id>_metadata` in the data cache
#'   ([ivt_cache_dir("data")][ivt_cache_dir]).
#' @return The output directory, invisibly.
#' @examples
#' path <- system.file("extdata", "98100044.ivt", package = "canivt")
#' ivt <- read_ivt(path)
#' out <- ivt_write_metadata(ivt, file.path(tempdir(), "98100044_metadata"))
#' list.files(out)
#' @export
ivt_write_metadata <- function(x, dir = NULL) {
  meta <- if (inherits(x, "ivt")) x$metadata else x
  if (is.null(dir)) dir <- ivt_data_cache_file(meta, "_metadata")
  dir.create(dir, showWarnings = FALSE, recursive = TRUE)

  wr <- function(df, name) utils::write.csv(df, file.path(dir, name),
                                            row.names = FALSE)

  members <- do.call(rbind, lapply(meta$dimensions, function(d) {
    if (!length(d$members)) return(NULL)
    ord <- d$ordinal
    if (is.null(ord) || length(ord) != length(d$members))
      ord <- seq_along(d$members)
    fr <- d$members_fr                              # NULL when only EN resolved
    label_fr <- if (!is.null(fr) && length(fr) == length(d$members))
      trimws(fr) else NA_character_
    data.frame(dimension = d$name,
               dimension_fr = if (is.null(d$name_fr)) NA_character_ else d$name_fr,
               member_id = seq_along(d$members),
               ordinal = as.integer(ord), label = trimws(d$members),
               label_fr = label_fr, depth = ivt_label_depth(d$members),
               parent_id = ivt_label_parent(d$members))
  }))
  wr(members, "dimension_members.csv")

  # every decoded geography column travels: bilingual labels/names, uid, then
  # whatever attributes the vintage stores (aggregation level, geography type /
  # municipal status, quality flag + note, non-response rate, presence). The
  # `geo_` prefix is dropped for the name-like columns (established file schema);
  # attribute columns keep their metadata names.
  geos <- meta$geographies
  geo_df <- data.frame(member_id = geos$member_id)
  renames <- c(geo_label = "label", geo_label_fr = "label_fr",
               geo_name = "name", geo_name_fr = "name_fr", geo_uid = "uid")
  for (col in names(renames))
    if (!is.null(geos[[col]])) geo_df[[renames[[col]]]] <- geos[[col]]
  for (col in setdiff(names(geos), c("member_id", names(renames))))
    if (!is.null(geos[[col]]) && length(geos[[col]]) == nrow(geo_df))
      geo_df[[col]] <- geos[[col]]
  wr(geo_df, "geographies.csv")

  if (length(meta$footnotes)) {
    na_chr <- function(x) if (is.null(x)) NA_character_ else x
    na_int <- function(x) if (is.null(x)) NA_integer_ else x
    fn <- do.call(rbind, lapply(meta$footnotes, function(f)
      data.frame(language = f$language, number = f$number,
                 scope = na_chr(f$scope), dimension = na_chr(f$dimension),
                 member_id = na_int(f$member_id),
                 # the full set of member ids a note annotates (";"-joined; a
                 # single legacy "(N)" note can cite many members)
                 member_refs = if (length(f$member_refs))
                                 paste(f$member_refs, collapse = ";") else NA_character_,
                 text = f$text)))
    wr(fn, "footnotes.csv")
  }

  # the data-quality-flag legend (code -> EN/FR text), when the table carries one
  if (!is.null(meta$dqf_legend) && nrow(meta$dqf_legend))
    wr(meta$dqf_legend, "dqf_legend.csv")

  wr(data.frame(field = c("product_id", "title_en", "title_fr", "universe"),
                value = c(meta$product_id, meta$title_en, meta$title_fr,
                          meta$universe)),
     "table_info.csv")
  invisible(dir)
}

# Default output path in the data cache for an ivt object (or metadata list),
# named by its StatCan product id. `suffix` is the extension (".parquet"/".csv")
# or a directory suffix ("_metadata"). Falls back to "table" when no product id.
ivt_data_cache_file <- function(x, suffix) {
  meta <- if (inherits(x, "ivt")) x$metadata else x
  pid <- meta$product_id
  if (is.null(pid) || is.na(pid) || !nzchar(pid)) pid <- "table"
  file.path(ivt_cache_dir("data"), paste0(pid, suffix))
}

# Leading-space count of each label (NA/empty -> 0, so the depth vector stays
# free of NAs for ivt_label_parent()).
ivt_label_indent <- function(labels) {
  lead <- nchar(labels) - nchar(sub("^ +", "", labels))
  lead[is.na(lead)] <- 0L
  as.integer(lead)
}

# Spaces per hierarchy level, read off the label set itself: the GCD of the
# observed indents. Most vintages indent two spaces per level, but not all --
# the census-of-agriculture geography axis (00040200/00040207/00040231) indents
# ONE, running Canada / province / CAR / CD / CCS at 0..4 spaces, where a fixed
# unit of 2 collapses five levels into three and makes each CD a sibling of the
# CAR that contains it. Returns 0 for a flat set (no indent anywhere).
ivt_label_indent_unit <- function(lead) {
  lead <- lead[lead > 0L]
  if (!length(lead)) return(0L)
  g <- lead[1L]
  for (x in lead[-1L]) { while (x) { t <- g %% x; g <- x; x <- t }; if (g == 1L) break }
  as.integer(g)
}

# Hierarchy depth implied by the leading-space indentation of a member label.
# `unit` is the spaces-per-level; the default of 2 is what every data dimension
# validated against, and callers that would rather let the labels declare it
# pass `ivt_label_indent_unit()`.
ivt_label_depth <- function(labels, unit = 2L) {
  lead <- ivt_label_indent(labels)
  if (unit < 1L) return(integer(length(lead)))
  as.integer(lead %/% as.integer(unit))
}

# Parent member (1-based member id) of each label in the hierarchy the
# indentation implies: the nearest PRECEDING member at a strictly smaller depth
# (robust to depth skips, e.g. 0 -> 2). NA for top-level (depth 0) members. This
# turns the flat depth sequence into a structured parent/child tree -- the
# family-2 analogue of the depth column, usable to roll members up to their
# aggregate ("Under $10,000" -> "With income" -> "Total - Income groups").
ivt_label_parent <- function(labels, unit = 2L) {
  d <- ivt_label_depth(labels, unit = unit)
  parent <- rep(NA_integer_, length(d))
  last_at <- integer(0)                         # last_at[k] = latest member at depth k-1
  for (i in seq_along(d)) {
    di <- d[i]
    if (di > 0L && length(last_at) >= 1L)       # nearest preceding SHALLOWER member:
      for (k in seq.int(min(di, length(last_at)), 1L))   # scan up from depth di-1
        if (!is.na(last_at[k])) { parent[i] <- last_at[k]; break }
    if (length(last_at) > di + 1L)              # returning to a shallower level:
      last_at[(di + 2L):length(last_at)] <- NA_integer_   # clear the stale deeper ids
    last_at[di + 1L] <- i
  }
  parent
}
