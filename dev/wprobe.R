# wprobe.R -- what the `0xa` status array says at code widths OTHER than 2.
#
# The addressing is general (see R/status.R): header `[form][02][W]`, a `[01][W]`
# intro, then codes W bits MSB-first at `lay$grid$bit`. Only the W = 2 VOCABULARY
# is validated. This script reads the codes at every width and tallies them by
# cell class -- PRESENT (carries a value), PADDING (a grid position the decoder
# drops as no cell at all) and ABSENT (a real cell with no value) -- so the
# candidate meanings can be compared against published symbol counts.
#
#   Rscript dev/wprobe.R [table-key ...]
#
# Env: CANIVT_IVT_CACHE (corpus root; falls back to ~/data/ivt_raw).

pkg <- Sys.getenv("CANIVT_PKG"); if (!nzchar(pkg)) pkg <- "."
suppressMessages(devtools::load_all(pkg))
cache <- Sys.getenv("CANIVT_IVT_CACHE")
if (!nzchar(cache)) cache <- path.expand("~/data/ivt_raw")

source(file.path(pkg, "dev", "wprobe-core.R"), local = TRUE)

cf <- function(k) {
  h <- list.files(file.path(cache, k), pattern = "\\.ivt$", ignore.case = TRUE,
                  full.names = TRUE)
  if (length(h)) h[[1L]] else NA_character_
}

# Walk every page of a table and tally codes by cell class.
wp_table <- function(key, max_pages = Inf) {
  f <- cf(key); if (is.na(f)) { cat(key, ": no file\n"); return(NULL) }
  raw <- readBin(f, "raw", file.size(f))
  lay <- ivt_quietly(ivt_layout(raw))
  idx0 <- ivt_idx0(raw); n <- length(raw)
  coord <- as.matrix(expand.grid(lapply(lay$ent_counts, function(c) 0:(c - 1L)),
                                 KEEP.OUT.ATTRS = FALSE))
  eidx <- as.integer(coord %*% lay$estride)
  win_col <- coord[, 1L]; ipc1 <- lay$ipc[1L]
  tup <- lay$grid$tuples; inpage_dim <- lay$inpage_idx

  # PADDING: the grid positions the decoder drops as no cell at all -- the
  # straddle's window tail past the member count, and any slot the file never
  # allocated. Straight from the layout (descriptor + slot geometry), never from
  # the status bytes, so code-1-is-padding stays two independent derivations.
  pad_of <- function(r) {
    p <- rep(FALSE, nrow(tup))
    for (t in seq_along(inpage_dim)) {
      j <- inpage_dim[t]
      mid <- if (j == lay$straddle) win_col[r] * ipc1 + tup[, t] else tup[, t]
      sp <- lay$slot_pos[[j]]
      p <- p | if (!is.null(sp)) is.na(match(mid, sp)) else mid > lay$counts[j]
    }
    p
  }

  tal <- list(); wtab <- integer(0); npage <- 0L
  for (r in seq_len(nrow(coord))) {
    if (npage >= max_pages) break
    en <- ivt_dir_entry(raw, idx0 + eidx[r] * 8L, n)
    if (is.null(en) || !en$marker) next
    pad <- pad_of(r)
    p <- tryCatch(wp_page(raw, en$off, lay, en$size), error = function(e) NULL)
    if (is.null(p)) next
    npage <- npage + 1L
    w <- as.character(p$width)
    wtab[w] <- (if (is.na(wtab[w])) 0L else wtab[w]) + 1L
    pr <- ivt_f2_record_present(raw, en$off + 4L, lay$rec_bytes, lay$grid$bit)
    cls <- ifelse(pr, "present", ifelse(pad, "padding", "absent"))
    t <- table(cls, p$codes)
    if (is.null(tal[[w]])) tal[[w]] <- t else {
      # merge two contingency tables with possibly different code sets
      cs <- union(colnames(tal[[w]]), colnames(t))
      rs <- union(rownames(tal[[w]]), rownames(t))
      m <- matrix(0L, length(rs), length(cs), dimnames = list(rs, cs))
      m[rownames(tal[[w]]), colnames(tal[[w]])] <-
        m[rownames(tal[[w]]), colnames(tal[[w]])] + tal[[w]]
      m[rownames(t), colnames(t)] <- m[rownames(t), colnames(t)] + t
      tal[[w]] <- m
    }
  }
  cat("\n==", key, "-- pages", npage, " widths:",
      paste(names(wtab), wtab, sep = "x", collapse = " "), "\n")
  for (w in names(tal)) { cat("-- W =", w, "\n"); print(tal[[w]]) }
  invisible(tal)
}

mp <- suppressWarnings(as.numeric(Sys.getenv("WPROBE_MAX_PAGES")))
if (is.na(mp)) mp <- Inf
keys <- commandArgs(trailingOnly = TRUE)
if (!length(keys)) keys <- c("98-400-X2016203")
for (k in keys) try(wp_table(k, mp))
