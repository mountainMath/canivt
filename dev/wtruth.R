# wtruth.R -- whole-table `0xa` status-code census, at every code width.
#
# Emits one tidy row per (table, width, cell class, code) so the codes can be
# matched against the SYMBOL counts of StatCan's published table. The cell class
# comes from the layout alone (descriptor + slot geometry), never from the status
# bytes, so "code k means symbol s" stays two independent derivations.
#
#   Rscript dev/wtruth.R out.csv <table-key> [<table-key> ...]
#
# Env: CANIVT_IVT_CACHE (corpus root; falls back to ~/data/ivt_raw),
# CANIVT_TEST_CORES (workers; default half the cores).

pkg <- Sys.getenv("CANIVT_PKG"); if (!nzchar(pkg)) pkg <- "."
suppressMessages(devtools::load_all(pkg))
cache <- Sys.getenv("CANIVT_IVT_CACHE")
if (!nzchar(cache)) cache <- path.expand("~/data/ivt_raw")
source(file.path(pkg, "dev", "wprobe-core.R"), local = TRUE)

args <- commandArgs(trailingOnly = TRUE)
out_csv <- args[1L]; keys <- args[-1L]

wt_one <- function(key) {
  f <- list.files(file.path(cache, key), pattern = "\\.ivt$", ignore.case = TRUE,
                  full.names = TRUE)[1L]
  if (is.na(f)) return(NULL)
  raw <- readBin(f, "raw", file.size(f))
  lay <- ivt_quietly(ivt_layout(raw))
  idx0 <- ivt_idx0(raw); n <- length(raw)
  coord <- as.matrix(expand.grid(lapply(lay$ent_counts, function(c) 0:(c - 1L)),
                                 KEEP.OUT.ATTRS = FALSE))
  eidx <- as.integer(coord %*% lay$estride)
  win_col <- coord[, 1L]; ipc1 <- lay$ipc[1L]
  tup <- lay$grid$tuples; inpage_dim <- lay$inpage_idx

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

  # class x code counts (tabulate, not table(): 1.3M pages) and, per page, the
  # width against the smallest width that could hold the page's largest code --
  # the test of whether W is a STORAGE choice rather than a change of vocabulary.
  NC <- 256L
  tal <- list(); pg <- list(); npage <- 0L
  add <- function(l, k, v) { o <- l[[k]]; l[[k]] <- if (is.null(o)) v else o + v; l }
  for (r in seq_len(nrow(coord))) {
    en <- ivt_dir_entry(raw, idx0 + eidx[r] * 8L, n)
    if (is.null(en) || !en$marker) next
    p <- tryCatch(wp_page(raw, en$off, lay, en$size), error = function(e) NULL)
    if (is.null(p)) next
    npage <- npage + 1L
    pr <- ivt_f2_record_present(raw, en$off + 4L, lay$rec_bytes, lay$grid$bit)
    pd <- pad_of(r)
    cd <- p$codes
    for (cl in c("present", "padding", "absent")) {
      sel <- switch(cl, present = pr, padding = !pr & pd, absent = !pr & !pd)
      if (any(sel)) tal <- add(tal, paste(p$width, cl, sep = "|"),
                               tabulate(cd[sel] + 1L, NC))
    }
    pg <- add(pg, paste(p$width, max(cd), sep = "|"), 1L)
  }
  if (!npage) return(NULL)
  rows <- do.call(rbind, lapply(names(tal), function(k) {
    v <- tal[[k]]; nz <- which(v > 0)
    sp <- strsplit(k, "|", fixed = TRUE)[[1L]]
    data.frame(key = key, pages = npage, width = as.integer(sp[1L]),
               class = sp[2L], code = nz - 1L, n = v[nz],
               row.names = NULL, stringsAsFactors = FALSE)
  }))
  prows <- do.call(rbind, lapply(names(pg), function(k) {
    sp <- strsplit(k, "|", fixed = TRUE)[[1L]]
    data.frame(key = key, pages = npage, width = as.integer(sp[1L]),
               class = "PAGEMAX", code = as.integer(sp[2L]), n = pg[[k]],
               row.names = NULL, stringsAsFactors = FALSE)
  }))
  rbind(rows, prows)
}

cores <- suppressWarnings(as.integer(Sys.getenv("CANIVT_TEST_CORES")))
if (is.na(cores)) cores <- max(1L, parallel::detectCores() %/% 2L)
res <- parallel::mclapply(keys, function(k)
  tryCatch(wt_one(k), error = function(e) data.frame(key = k, pages = NA, width = NA,
    class = paste("ERROR:", conditionMessage(e)), code = NA, n = NA)), mc.cores = cores)
df <- do.call(rbind, Filter(Negate(is.null), res))
df <- df[order(df$key, df$width, df$class, df$code), ]
utils::write.csv(df, out_csv, row.names = FALSE)
print(df, row.names = FALSE)
