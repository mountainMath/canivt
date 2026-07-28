# wcoord.R -- WHERE a given `0xa` status code lands, in member coordinates.
#
# Companion to dev/wprobe.R (which only tallies). This maps the cells carrying a
# chosen code back to member ids and labels, so the coordinate can be looked up
# in StatCan's published table / Beyond 20/20 viewer and the code's MEANING read
# off directly. Walks pages lazily and stops at `n`, so it works on tables far
# too large to decode whole.
#
#   Rscript dev/wcoord.R <table-key> <code> [n] [skip-pages] [only-width]
#
# Env: CANIVT_IVT_CACHE (corpus root; falls back to ~/data/ivt_raw).

pkg <- Sys.getenv("CANIVT_PKG"); if (!nzchar(pkg)) pkg <- "."
suppressMessages(devtools::load_all(pkg))
cache <- Sys.getenv("CANIVT_IVT_CACHE")
if (!nzchar(cache)) cache <- path.expand("~/data/ivt_raw")
source(file.path(pkg, "dev", "wprobe-core.R"), local = TRUE)

args <- commandArgs(trailingOnly = TRUE)
key <- args[1L]
want <- as.integer(args[2L])
n_want <- if (length(args) >= 3L) as.integer(args[3L]) else 20L
skip <- if (length(args) >= 4L) as.integer(args[4L]) else 0L
only_w <- if (length(args) >= 5L) as.integer(args[5L]) else NA_integer_

f <- list.files(file.path(cache, key), pattern = "\\.ivt$", ignore.case = TRUE,
                full.names = TRUE)[1L]
raw <- readBin(f, "raw", file.size(f))
lay <- ivt_quietly(ivt_layout(raw))
meta <- ivt_quietly(ivt_metadata(f))
idx0 <- ivt_idx0(raw); n <- length(raw)

coord <- as.matrix(expand.grid(lapply(lay$ent_counts, function(c) 0:(c - 1L)),
                               KEEP.OUT.ATTRS = FALSE))
eidx <- as.integer(coord %*% lay$estride)
ne <- length(lay$ent_counts)
win_col <- coord[, 1L]; ipc1 <- lay$ipc[1L]
paged_member <- if (ne > 1L) coord[, -1L, drop = FALSE] else NULL
paged_dim <- if (ne > 1L) lay$ent_idx[-1L] else integer(0)
inpage_dim <- lay$inpage_idx
tup <- lay$grid$tuples
m <- lay$n_dim

# Full member-id coordinates for the grid rows `rows` of directory entry `r` --
# the same mapping decode.R makes, slot maps included.
md_of <- function(rows, r) {
  md <- matrix(0L, length(rows), m)
  for (t in seq_along(inpage_dim)) {
    j <- inpage_dim[t]
    md[, j] <- if (j == lay$straddle) win_col[r] * ipc1 + tup[rows, t] else tup[rows, t]
  }
  if (length(paged_dim)) for (t in seq_along(paged_dim))
    md[, paged_dim[t]] <- paged_member[r, t] + 1L
  for (j in seq_len(m)) {
    sp <- lay$slot_pos[[j]]
    if (!is.null(sp)) md[, j] <- match(md[, j], sp)
  }
  md
}

hits <- list(); got <- 0L; seen <- 0L
for (r in seq_len(nrow(coord))) {
  if (got >= n_want) break
  en <- ivt_dir_entry(raw, idx0 + eidx[r] * 8L, n)
  if (is.null(en) || !en$marker) next
  p <- tryCatch(wp_page(raw, en$off, lay, en$size), error = function(e) NULL)
  if (is.null(p)) next
  if (!is.na(only_w) && p$width != only_w) next
  seen <- seen + 1L
  if (seen <= skip) next
  rows <- which(p$codes == want)
  if (!length(rows)) next
  rows <- rows[seq_len(min(length(rows), n_want - got))]
  md <- md_of(rows, r)
  hits[[length(hits) + 1L]] <- cbind(page = r, width = p$width, md)
  got <- got + length(rows)
}

if (!length(hits)) { cat("no cells with code", want, "in", seen, "pages\n"); quit() }
h <- do.call(rbind, hits)
colnames(h) <- c("page", "width", meta$dimension_names)
cat("\n==", key, "-- code", want, "--", nrow(h), "cells over", seen, "pages\n\n")
print(utils::head(as.data.frame(h), n_want))

cat("\n-- labels --\n")
for (j in seq_len(m)) {
  ids <- unique(h[, j + 2L])
  mem <- meta$dimensions[[j]]$members
  lab <- if (is.character(mem)) mem[ids] else rep(NA_character_, length(ids))
  cat(sprintf("%s [%s]: %s\n", meta$dimension_names[j],
              paste(ids, collapse = ","),
              paste(substr(lab, 1, 70), collapse = " | ")))
}
