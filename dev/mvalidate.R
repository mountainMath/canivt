# mvalidate.R -- semantic validation of the 0x8 absent mask, from arithmetic
# alone (no external ground truth).
#
# The mask splits absent cells into genuine zeros (masked) and missings
# (unmasked). Both halves are testable inside the file wherever a dimension
# carries a "Total" member over its own detail members, because the total is
# published even when the detail is suppressed:
#
#   masked   absent => genuine ZERO    => total - sum(present detail) ~ 0
#   unmasked absent => MISSING (real,  => total - sum(present detail) > 0
#                      unpublished value)
#
# The design is self-calibrating: the CONTROL group is the set of coordinates
# where every absent detail cell is masked, and it establishes both that the
# dimension really is additive and how much noise the vintage's random rounding
# adds. The TREATMENT groups -- one per count of cells the decoder reports
# missing -- must then show a residual that GROWS with that count. If instead
# "unmasked absent" meant zero, both groups would sit at 0.
#
#   Rscript dev/mvalidate.R <corpus-key> [dimension-slug]
#
# The dimension defaults to the first data dimension whose member 1 is labelled
# "Total ...". Env: CANIVT_IVT_CACHE (default ~/data/ivt_raw), CANIVT_PKG.

pkg <- Sys.getenv("CANIVT_PKG"); if (!nzchar(pkg)) pkg <- "."
suppressMessages(devtools::load_all(pkg))

args  <- commandArgs(trailingOnly = TRUE)
key   <- args[1L]
want  <- args[2L]
cache <- Sys.getenv("CANIVT_IVT_CACHE")
if (!nzchar(cache)) cache <- path.expand("~/data/ivt_raw")
if (is.na(key)) stop("usage: Rscript dev/mvalidate.R <corpus-key> [dimension-slug]")

f <- list.files(file.path(cache, key), pattern = "\\.ivt$", ignore.case = TRUE,
                full.names = TRUE)
if (!length(f)) stop("no .ivt under ", file.path(cache, key))

x <- ivt_quietly(read_ivt(f[[1L]], missing = TRUE))
C <- x$cells; M <- x$missing
dims <- x$metadata$dimensions
slugs <- setdiff(names(C), "value")

# ---- pick the additive dimension --------------------------------------------
is_total <- function(d)
  !isTRUE(d$is_geography) && d$count >= 3L &&
  length(d$members) && grepl("^\\s*Total", d$members[[1L]])
cand <- which(vapply(dims, is_total, logical(1)))
if (!is.na(want)) {
  j <- match(want, slugs)
  if (is.na(j)) stop("no dimension slug ", want, " in: ", paste(slugs, collapse = ", "))
} else {
  if (!length(cand)) stop("no dimension has a leading Total member; name one explicitly")
  j <- cand[[1L]]
}
cat(sprintf("%s: additive dimension %d = %s (%s), %d members\n",
            key, j, slugs[j], dims[[j]]$name, dims[[j]]$count))
cat("  member 1:", dims[[j]]$members[[1L]], "\n")

# ---- drop the non-additive members ------------------------------------------
# A median / average / rate member does not sum over the additive dimension, so
# it is noise here. This is a LABEL heuristic and it lives in a dev validation
# script on purpose -- nothing in the parser may key off member labels.
NONADD <- "(?i)\\b(median|average|moyenne|rate|ratio|per ?cent|per capita)\\b"
for (i in seq_along(slugs)) {
  if (i == j || !length(dims[[i]]$members)) next
  bad <- which(grepl(NONADD, dims[[i]]$members, perl = TRUE))
  if (!length(bad) || length(bad) == dims[[i]]$count) next
  cat(sprintf("  dropping %d non-additive member(s) of %s: %s\n", length(bad),
              slugs[i], paste(trimws(dims[[i]]$members[bad]), collapse = ", ")))
  C <- C[!(C[[slugs[i]]] %in% bad), ]
  M <- M[!(M[[slugs[i]]] %in% bad), ]
}

# ---- group by every OTHER dimension -----------------------------------------
# Integer keys: the cartesian of the remaining dimensions, encoded positionally.
other <- setdiff(seq_along(slugs), j)
mult <- cumprod(c(1, vapply(dims[other], function(d) as.numeric(d$count) + 1, 0)))
kof <- function(d) as.numeric(as.matrix(d[slugs[other]])) |>
  matrix(ncol = length(other)) %*% mult[seq_along(other)] |> drop()

tot <- C[C[[slugs[j]]] == 1L, ]
det <- C[C[[slugs[j]]] != 1L, ]
mis <- M[M[[slugs[j]]] != 1L, ]

kt <- kof(tot)
ds <- tapply(det$value, kof(det), sum)
nm <- table(kof(mis))
D <- data.frame(total = tot$value,
                dsum  = as.numeric(ds[as.character(kt)]),
                nmiss = as.integer(nm[as.character(kt)]))
D$dsum[is.na(D$dsum)] <- 0
D$nmiss[is.na(D$nmiss)] <- 0L
D$resid <- D$total - D$dsum

# Rounding tolerance: census counts are randomly rounded to base 5 and the
# residual accumulates over the dimension's members, so allow +-3 per member.
tol <- 3 * dims[[j]]$count

cat(sprintf("\n%d total cells; %d have every absent detail masked (CONTROL)\n",
            nrow(D), sum(D$nmiss == 0L)))
cat(sprintf("\n%-34s %8s %10s %10s %10s %9s\n",
            "group", "n", "median", "mean", paste0("|d|<=", tol), "frac d>0"))
grp <- ifelse(D$nmiss == 0L, "control: all detail accounted for",
              sprintf("%d cell(s) reported MISSING", D$nmiss))
for (lv in c("control: all detail accounted for",
             sort(setdiff(unique(grp), "control: all detail accounted for")))) {
  s <- D$resid[grp == lv]
  if (!length(s)) next
  cat(sprintf("%-34s %8d %10.1f %10.1f %10.3f %9.3f\n",
              lv, length(s), stats::median(s), mean(s), mean(abs(s) <= tol),
              mean(s > 0)))
}

ctl <- D$resid[D$nmiss == 0L]; trt <- D$resid[D$nmiss > 0L]
cat("\nVERDICT\n")
ok <- length(ctl) > 0 && abs(stats::median(ctl)) <= tol && mean(abs(ctl) <= tol) >= 0.5
cat(sprintf("  control median %.1f (want ~0), |d|<=%d on %.1f%%%s\n",
            stats::median(ctl), tol, 100 * mean(abs(ctl) <= tol),
            if (ok) "" else "   <- CONTROL FAILS: this dimension is not additive, test inapplicable"))
if (length(trt))
  cat(sprintf("  missing-bearing median %.1f, frac > 0 %.3f (want > control)\n",
              stats::median(trt), mean(trt > 0)))
mono <- vapply(split(D$resid, pmin(D$nmiss, dims[[j]]$count)), stats::median, 0)
cat("  median residual by number of cells reported missing:\n    ",
    paste(sprintf("%s:%g", names(mono), mono), collapse = "  "), "\n")
