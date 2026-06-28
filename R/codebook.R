#' IVT codebook: table identity, dimension members, geography ids, footnotes
#'
#' The codebook lives at the end of the file (after the value pages and the
#' footnote legend). For each dimension it stores several parallel,
#' member-ordered arrays of length-prefixed ("Pascal", 1-byte length,
#' 0x00-separated, latin-1) strings: member ordinals, the member name (EN then
#' FR) and, for Geography, the level name, abbreviations, classification code and
#' the full DGUID (e.g. "2021A000011124" = Canada). The file header (bytes
#' 0..~4400) carries the table identity and the dimension names.
#'
#' @keywords internal
#' @noRd
NULL

# Dimensions in IVT declaration order, with the distinctive English substring
# that identifies that dimension's English member-name block and the expected
# member count. Geography (handled separately) has no "Total -" member.
IVT_DIMS <- list(
  list(name = "Geography", keyword = NA_character_, count = NA_integer_),
  list(name = "Age of primary household maintainer",
       keyword = "Age of primary household", count = 9L),
  list(name = "Household type including census family structure",
       keyword = "Household type including", count = 16L),
  list(name = "Period of construction",
       keyword = "Period of construction", count = 13L),
  list(name = "Statistics", keyword = "Number of private households", count = 3L),
  list(name = "Housing indicators", keyword = "Housing indicators", count = 6L),
  list(name = paste0("Tenure including presence of mortgage payments ",
                     "and subsidized housing"),
       keyword = "Tenure including presence", count = 7L)
)

# Scan a region for maximal runs of consecutive Pascal records (member lists),
# tolerating a single 0x00 separator between records. Returns a list of blocks
# with $start (0-based) and $texts.
ivt_find_member_blocks <- function(raw, search_start, min_records = 3L) {
  n <- length(raw)
  blocks <- list()
  i <- search_start
  while (i < n) {
    rec <- rd_pascal(raw, i)
    if (is.null(rec)) { i <- i + 1L; next }
    texts <- character(0)
    start <- i
    j <- i
    repeat {
      rec <- rd_pascal(raw, j)
      if (is.null(rec)) {
        if (j < n && as.integer(raw[j + 1L]) == 0L &&
            !is.null(rd_pascal(raw, j + 1L))) { j <- j + 1L; next }
        break
      }
      texts <- c(texts, rec$text)
      j <- rec$end
      if (j < n && as.integer(raw[j + 1L]) == 0L &&
          !is.null(rd_pascal(raw, j + 1L))) j <- j + 1L
    }
    if (length(texts) >= min_records) {
      blocks[[length(blocks) + 1L]] <- list(start = start, texts = texts)
      i <- j
    } else {
      i <- i + 1L
    }
  }
  blocks
}

ivt_header_text <- function(raw, n = 8000L) {
  raw_to_latin1(raw[1:min(n, length(raw))])
}

ivt_table_info <- function(raw) {
  head <- ivt_header_text(raw)
  grab <- function(re) {
    m <- regmatches(head, regexec(re, head))[[1]]
    if (length(m) >= 2) trimws(m[2]) else NA_character_
  }
  list(
    product_id = grab("Product ID:\\s*([0-9]+)"),
    title_en   = grab("Title:\\s*([^\r\n]+)"),
    title_fr   = grab("Titre\\s*:\\s*([^\r\n]+)"),
    universe   = grab("Universe:\\s*([^\r\n]+)")
  )
}

# Geography arrays: among the equal-length member blocks, the name block starts
# with "Canada" and is not all-numeric; the DGUID block's entries all look like
# "2021<letter><digits>".
ivt_geo_arrays <- function(blocks, n) {
  sized <- Filter(function(b) length(b$texts) == n, blocks)
  name_block <- NULL
  dguid_block <- NULL
  for (b in sized) {
    if (is.null(dguid_block) && all(grepl("^2021[A-Z][0-9]", b$texts)))
      dguid_block <- b
    if (is.null(name_block) && b$texts[1] == "Canada" &&
        !all(grepl("^[0-9]+$", b$texts)))
      name_block <- b
  }
  list(names = name_block, dguids = dguid_block)
}

ivt_pick_english_block <- function(blocks, count, keyword) {
  for (b in blocks) {
    if (length(b$texts) == count && any(grepl(keyword, b$texts, fixed = TRUE)))
      return(b)
  }
  NULL
}

# A "text byte": printable ASCII, tab/newline/carriage-return, or latin-1
# accented range. Footnote prose is built only from these; the record framing
# (`00 01 01 <u16 length>`) always contains a NUL or sub-0x09 control byte, so
# each footnote is one maximal run of text bytes -- a far more robust delimiter
# than NULs alone (consecutive footnotes are sometimes separated only by the
# framing, with no NUL between them).
is_text_byte <- function(v) {
  (v >= 32L & v <= 126L) | v %in% c(9L, 10L, 13L) | (v >= 160L & v <= 255L)
}

# Extract footnotes from the codebook tail by isolating maximal text-byte runs
# and keeping those that begin (after optional leading whitespace) with a
# "Footnote N" (en) / "Renvoi N" (fr) marker. The text length prefix's high byte
# can be a whitespace text byte (\t \n \r), so it may prepend a stray space to
# the run -- hence the leading-whitespace tolerance. `number` is the footnote's
# position within its language in file order (not the StatCan Note ID, which the
# IVT does not record per footnote).
ivt_footnotes <- function(raw, search_start) {
  v <- as.integer(raw[(search_start + 1L):length(raw)])
  txt <- is_text_byte(v)
  r <- rle(txt)
  ends <- cumsum(r$lengths)
  starts <- ends - r$lengths + 1L
  marker <- "^[[:space:]]*(Footnote|Renvoi)[[:space:]]*([0-9]+)[[:space:]]*"
  langs <- c(Footnote = "en", Renvoi = "fr")
  counts <- c(en = 0L, fr = 0L)
  out <- list()
  for (i in which(r$values)) {
    if (r$lengths[i] < 12L) next  # too short to be a footnote
    s <- raw_to_latin1(raw[search_start + starts[i]:ends[i]])
    m <- regmatches(s, regexec(marker, s))[[1]]
    if (length(m) < 3L) next
    lang <- unname(langs[m[2]])
    body <- trimws(gsub(" ", " ", sub(marker, "", s)))
    body <- gsub("[[:space:]]+", " ", body)
    if (!nzchar(body)) next
    counts[lang] <- counts[lang] + 1L
    out[[length(out) + 1L]] <- list(language = lang,
                                    number = counts[[lang]], text = body)
  }
  out
}

#' Read the full IVT codebook from a raw vector.
#' @return a list: table info, `dimensions` (each with `members`), `geographies`
#'   (name + dguid + member_id), and `footnotes`.
#' @keywords internal
#' @noRd
ivt_read_codebook <- function(raw, tail_bytes = 200000L) {
  info <- ivt_table_info(raw)
  search_start <- max(0L, length(raw) - tail_bytes)
  blocks <- ivt_find_member_blocks(raw, search_start, min_records = 3L)

  big <- Filter(function(b) length(b$texts) > 100L, blocks)
  ngeo <- if (length(big)) min(vapply(big, function(b) length(b$texts), 1L)) else 0L
  geo <- ivt_geo_arrays(blocks, ngeo)
  names_v <- if (!is.null(geo$names)) geo$names$texts else character(0)
  dguid_v <- if (!is.null(geo$dguids)) geo$dguids$texts else character(0)

  dims <- lapply(IVT_DIMS, function(d) {
    if (is.na(d$keyword)) {
      list(name = d$name, count = length(names_v), members = names_v)
    } else {
      b <- ivt_pick_english_block(blocks, d$count, d$keyword)
      list(name = d$name, count = d$count,
           members = if (!is.null(b)) b$texts else character(0))
    }
  })

  list(
    product_id = info$product_id, title_en = info$title_en,
    title_fr = info$title_fr, universe = info$universe,
    dimensions = dims,
    geographies = list(name = names_v, dguid = dguid_v,
                       member_id = seq_along(names_v)),
    footnotes = ivt_footnotes(raw, search_start)
  )
}
