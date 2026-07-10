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

# A "text byte": printable ASCII, tab/newline/carriage-return, or latin-1
# accented range. Footnote prose is built only from these; the record framing
# (`00 01 01 <u16 length>`) always contains a NUL or sub-0x09 control byte, so
# each footnote is one maximal run of text bytes -- a far more robust delimiter
# than NULs alone (consecutive footnotes are sometimes separated only by the
# framing, with no NUL between them).
is_text_byte <- function(v) {
  (v >= 32L & v <= 126L) | v %in% c(9L, 10L, 13L) | (v >= 160L & v <= 255L)
}

# Footnote texts inside the byte window [from, to) (0-based), by isolating
# maximal text-byte runs and keeping those that begin (after optional leading
# whitespace) with a "Footnote N" (en) / "Renvoi N" (fr) marker. The text length
# prefix's high byte can be a whitespace text byte (\t \n \r), so it may prepend
# a stray space to the run -- hence the leading-whitespace tolerance. Returns a
# list of list(language, text) in window order; numbering is the caller's
# concern (the tail scan and the per-dimension directory read number
# differently).
ivt_footnote_texts <- function(raw, from, to = length(raw)) {
  search_start <- from
  to <- min(to, length(raw))
  if (search_start >= to) return(list())
  v <- as.integer(raw[(search_start + 1L):to])
  txt <- is_text_byte(v)
  r <- rle(txt)
  ends <- cumsum(r$lengths)
  starts <- ends - r$lengths + 1L
  marker <- "^[[:space:]]*(Footnote|Renvoi)[[:space:]]*([0-9]+)[[:space:]]*"
  langs <- c(Footnote = "en", Renvoi = "fr")
  # the 1981 profile vintage frames its footnotes "FOOTNOTE:<text>" /
  # "RENVOI :<text>" -- all-caps, colon-terminated, no number (numbering is the
  # caller's job under both forms). Case-sensitive on purpose so the two shapes
  # cannot cross-match.
  marker2 <- "^[[:space:]]*(FOOTNOTE|RENVOI)[[:space:]]*:[[:space:]]*"
  langs2 <- c(FOOTNOTE = "en", RENVOI = "fr")
  out <- list()
  for (i in which(r$values)) {
    if (r$lengths[i] < 12L) next  # too short to be a footnote
    s <- raw_to_latin1(raw[search_start + starts[i]:ends[i]])
    use <- marker
    m <- regmatches(s, regexec(marker, s))[[1]]
    if (length(m) >= 3L) {
      lang <- unname(langs[m[2]])
    } else {
      m <- regmatches(s, regexec(marker2, s))[[1]]
      if (length(m) < 2L) next
      use <- marker2
      lang <- unname(langs2[m[2]])
    }
    body <- trimws(gsub("\u00a0", " ", sub(use, "", s)))
    body <- gsub("[[:space:]]+", " ", body)
    if (!nzchar(body)) next
    out[[length(out) + 1L]] <- list(language = lang, text = body)
  }
  out
}

# Extract footnotes from the codebook tail (fallback for files without a header
# dimension slot table; the primary path is `ivt_f2_dir_footnotes()`, which also
# attributes each footnote to its owning dimension). `number` is the footnote's
# position within its language in file order (not the StatCan Note ID, which the
# IVT does not record per footnote).
ivt_footnotes <- function(raw, search_start) {
  counts <- c(en = 0L, fr = 0L)
  out <- list()
  for (f in ivt_footnote_texts(raw, search_start)) {
    counts[f$language] <- counts[[f$language]] + 1L
    out[[length(out) + 1L]] <- list(language = f$language,
                                    number = counts[[f$language]], text = f$text)
  }
  out
}

