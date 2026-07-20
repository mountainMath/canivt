# Code for the canivt package hex sticker.
#
# The motif is a *presence bitmap*: canivt's job is to decode Beyond 20/20
# `.ivt` files, whose cells are stored as a power-of-two-nested positional
# presence bitmap over the raw bytes. Here we render a real window of the
# bundled sample `.ivt` as its literal on/off bits — the very bytes the
# parser walks — as a grid of lit / dark cells. Gold-on-charcoal with a red
# hex border, matching the canpumf sticker family.

library(ggplot2)
library(hexSticker)

# --- the real bytes canivt parses ---------------------------------------
f <- system.file("extdata", "98100044.ivt", package = "canivt")
if (f == "") f <- here::here("inst/extdata/98100044.ivt")
raw <- readBin(f, "raw", file.info(f)$size)

# A square window over the data/presence region, laid out as its bits
# (MSB-first per byte, row-major) — a genuine slice of the binary format.
ncol  <- 40                       # columns of bits
nrow  <- 40                       # total rows; the bottom band is left clear
band  <- 11                       # blank rows reserved for the wordmark
keep  <- nrow - band
start <- 3000                     # into the value/presence region
bytes <- raw[start:(start + ncol * keep / 8 - 1)]
bits  <- as.integer(rawToBits(bytes))            # LSB-first from rawToBits
m     <- matrix(bits, nrow = keep, ncol = ncol, byrow = TRUE)

grid <- expand.grid(row = seq_len(keep), col = seq_len(ncol))
grid$on <- as.vector(t(m)) == 1L

# Draw ONLY the lit cells; the hexagon's charcoal fill shows through as the
# "off" cells, so there is no bounding square to bleed past the hex edges.
lit <- grid[grid$on, ]

p <- ggplot(lit, aes(col, -row)) +
  geom_tile(fill = "#F2C200", color = "#333333", linewidth = 0.3) +
  coord_equal(xlim = c(0.5, ncol + 0.5), ylim = c(-nrow - 0.5, -0.5),
              expand = FALSE) +
  theme_void() +
  theme_transparent()

# --- the sticker ---------------------------------------------------------
s <- sticker(
  p,
  package  = "canivt",
  s_x = 1, s_y = 0.95, s_width = 1.3, s_height = 1.3,
  p_y = 0.48, p_size = 42, p_color = "#F2C200",
  h_color = "#E60013", h_fill = "#333333", h_size = 3
) +
  theme_transparent() +
  theme(panel.grid = element_blank(),
        panel.grid.major = element_blank(), # Removes main gridlines
        panel.grid.minor = element_blank(), # Removes minor gridlines
        panel.background = element_blank(),
        plot.background = element_blank(),
        panel.border = element_blank())


out <- if (requireNamespace("here", quietly = TRUE))
  here::here("man/figures/logo.png") else "man/figures/logo.png"
ggsave(out, s, width = 3.5, height = 3.5, bg = "transparent")
