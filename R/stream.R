#' Convert an IVT to Parquet/CSV a chunk at a time
#'
#' The published table of a large `.ivt` is an order of magnitude bigger than
#' the store it is folded out of -- the corpus grid runs to 4.3 billion rows
#' against 366 million stored cells -- so materialising it whole is what puts a
#' table out of reach on a small machine, not reading the file. But the fold is
#' positional: the entry cartesian's outermost paged dimension varies slowest,
#' so a slice of it is a contiguous run of output rows that can be decoded,
#' written and dropped. This is the streaming path that does that
#' (`ivt_write_parquet()` / `ivt_write_csv()` reach it by being handed a file
#' path instead of an `ivt` object).
#'
#' @keywords internal
#' @noRd
NULL

# How the published grid splits into chunks along the OUTERMOST paged dimension:
# a list of 0-based member-index vectors for `ivt_decode(outer = )`, or
# `list(NULL)` (decode in one piece) when the whole grid fits `max_cells` or the
# layout has no paged dimension outside the straddle window.
#
# The chunk is measured in GRID ROWS, which is what the memory cost tracks --
# every coordinate is emitted whether or not the file stored a value for it.
ivt_chunk_plan <- function(lay, max_cells = getOption("canivt.chunk_cells",
                                                      5e6)) {
  ne <- length(lay$ent_counts)
  ngrid <- prod(as.numeric(lay$counts))
  if (ne < 2L || !is.finite(max_cells) || max_cells <= 0 || ngrid <= max_cells)
    return(list(NULL))
  n_out <- lay$ent_counts[[ne]]
  # Rows per member of the outermost paged dimension. A single member is the
  # finest slice there is -- if one is already over budget the chunks are as
  # small as this layout goes, and the caller is told rather than refused.
  per <- ngrid / n_out
  k <- max(1L, as.integer(floor(max_cells / per)))
  idx <- 0:(n_out - 1L)
  unname(split(idx, idx %/% k))
}

# Decode chunk `w` of `file` as a one-chunk `ivt` object -- the same shape
# `read_ivt()` returns, so every labelling/tidying path downstream is the one
# that serves a whole table. `meta` and `lay` are read once by the caller.
ivt_chunk_ivt <- function(raw, lay, meta, family, path, w) {
  cells <- ivt_decode(raw, lay = lay, complete = TRUE, outer = w)
  structure(list(cells = cells, metadata = meta, path = path, family = family,
                 missing = ivt_flagged_cells(cells)), class = "ivt")
}

# The streaming conversion itself. `format` picks the sink; everything else is
# `ivt_write_parquet()` / `ivt_write_csv()`'s own arguments, applied per chunk
# so the written table is byte-for-byte what the whole-table path would write.
ivt_write_stream <- function(file, path, format, labels, members, missing,
                             dim_names, language, chunk_cells, compress = TRUE,
                             ...) {
  if (!file.exists(file))
    cli::cli_abort("No such file: {.path {file}}.")
  raw <- readBin(file, "raw", file.info(file)$size)
  on.exit(ivt_memo_clear(), add = TRUE)
  family <- ivt_family(raw)
  if (is.na(family))
    cli::cli_abort("Unsupported or unrecognised IVT format in {.path {file}}.")
  lay <- ivt_layout(raw)
  meta <- ivt_f2_metadata(raw)
  if (is.null(path))
    path <- ivt_data_cache_file(meta, paste0("_", language,
                                             if (format == "parquet") ".parquet"
                                             else ".csv"))
  if (format == "csv") path <- ivt_csv_path(path, compress)
  plan <- ivt_chunk_plan(lay, chunk_cells)
  # The whole grid a chunk at a time is the point of this path, so the
  # `canivt.max_cells` guard does not apply -- but a layout that cannot be
  # sliced finely enough still says so, rather than quietly allocating.
  ngrid <- prod(as.numeric(lay$counts))
  if (length(plan) == 1L && is.null(plan[[1L]])) ivt_complete_budget(lay)

  sink <- ivt_sink_open(path, format, ...)
  msink <- NULL
  on.exit({
    ivt_sink_close(sink)
    if (!is.null(msink)) ivt_sink_close(msink)
  }, add = TRUE)

  nrows <- 0
  for (i in seq_along(plan)) {
    x <- ivt_chunk_ivt(raw, lay, meta, family, file, plan[[i]])
    td <- ivt_tidy(x, labels = labels, dim_names = dim_names,
                   language = language)
    nrows <- nrows + nrow(td)
    ivt_sink_write(sink, td)
    # The member sidecar is table-wide, so it is written from the first chunk --
    # which is simply the first `ivt` object in hand (`ivt_members()` reads the
    # metadata, and takes the data-column names from `cells`).
    if (i == 1L && isTRUE(members) && format == "parquet") {
      mem <- ivt_members(x, dim_names = dim_names, language = language)
      if (nrow(mem)) arrow::write_parquet(mem, ivt_members_path(path))
    }
    # The sidecar is written even when no chunk flags a cell: an empty one says
    # "this table declares no missings", which is not the same statement as no
    # sidecar at all ("decoded without the status block"). The streaming path
    # always reads the status block, so it always has something to say.
    if (isTRUE(missing)) {
      if (is.null(msink))
        msink <- ivt_sink_open(ivt_stream_missing_path(path, format), format,
                               ...)
      ivt_sink_write(msink, ivt_tidy_missing(x, labels = labels,
                                             dim_names = dim_names,
                                             language = language))
    }
    rm(x, td); gc(verbose = FALSE)
  }
  if (nrows != ngrid)
    cli::cli_abort(paste(
      "Streamed {nrows} row{?s} for a grid of {ngrid} -- the chunk plan did not",
      "cover the table."))
  invisible(path)
}

ivt_stream_missing_path <- function(path, format) {
  if (format == "parquet") ivt_missing_path(path) else ivt_csv_missing_path(path)
}

# --- CSV paths -----------------------------------------------------------------
#
# Gzip is the default (see `ivt_write_csv()`), and the EXTENSION is the truth
# about the file: a path already ending in `.gz` is compressed whatever
# `compress` says, and `compress = TRUE` appends `.gz` to one that is not.
ivt_csv_path <- function(path, compress = TRUE) {
  if (ivt_csv_is_gz(path)) path else if (isTRUE(compress)) paste0(path, ".gz")
  else path
}

ivt_csv_is_gz <- function(path) grepl("\\.gz$", path, ignore.case = TRUE)

# `<name>.csv[.gz]` -> `<name>_missing.csv[.gz]`: the sidecar keeps the data
# table's own compression, so the pair is always written and read the same way.
ivt_csv_missing_path <- function(path) {
  gz <- ivt_csv_is_gz(path)
  base <- if (gz) substr(path, 1L, nchar(path) - 3L) else path
  ext <- regmatches(base, regexpr("\\.csv$", base, ignore.case = TRUE))
  if (length(ext)) base <- substr(base, 1L, nchar(base) - 4L) else ext <- ".csv"
  paste0(base, "_missing", ext, if (gz) ".gz" else "")
}

# --- the two sinks -------------------------------------------------------------
#
# Both are open-write-close, so the chunk loop above never branches on format.
# The Parquet writer needs a schema before the first chunk, so it is created
# lazily from it; every later chunk must match, which it does because the
# columns are labelled from table-wide metadata and the `symbol`/`status` factor
# levels come from the file's own `@698` legend.
#
# The CSV sink holds ONE connection open across the whole conversion -- a
# `gzfile()` when the path ends in `.gz` -- so a chunked write is a single gzip
# stream, not a concatenation of members, and the header is written once.

ivt_sink_open <- function(path, format, ...) {
  if (format == "parquet" && !requireNamespace("arrow", quietly = TRUE))
    cli::cli_abort("Package {.pkg arrow} is required to write Parquet.")
  e <- new.env(parent = emptyenv())
  e$path <- path; e$format <- format; e$args <- list(...); e$writer <- NULL
  if (format == "csv")
    e$con <- if (ivt_csv_is_gz(path)) gzfile(path, "wb") else file(path, "wb")
  e
}

ivt_sink_write <- function(e, df) {
  if (e$format == "csv") {
    first <- is.null(e$writer)
    e$writer <- TRUE
    if (requireNamespace("readr", quietly = TRUE))
      do.call(readr::write_csv, c(list(df, e$con, append = !first), e$args))
    else
      do.call(utils::write.table,
              c(list(df, e$con, row.names = FALSE, col.names = first,
                     sep = ",", qmethod = "double"), e$args))
    return(invisible(NULL))
  }
  tbl <- arrow::as_arrow_table(df)
  if (is.null(e$writer)) {
    e$stream <- arrow::FileOutputStream$create(e$path)
    # `...` reaches `write_parquet()` on the in-memory path, so it is the
    # writer PROPERTIES here -- which need the column names the schema already
    # carries.
    props <- do.call(arrow::ParquetWriterProperties$create,
                     c(list(column_names = names(df)), e$args))
    e$writer <- arrow::ParquetFileWriter$create(tbl$schema, e$stream,
                                                properties = props)
  }
  e$writer$WriteTable(tbl, chunk_size = nrow(df))
  invisible(NULL)
}

ivt_sink_close <- function(e) {
  if (e$format == "csv") {
    if (!is.null(e$con)) { close(e$con); e$con <- NULL }
  } else if (!is.null(e$writer)) {
    e$writer$Close()
    e$stream$close()
  }
  invisible(NULL)
}
