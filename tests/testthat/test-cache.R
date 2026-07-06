# Cache-path configuration: options, the .Renviron bridge, and tempdir fallbacks.

test_that("ivt_cache_dir falls back to tempdir when the option is unset", {
  withr::local_options(canivt.ivt_cache = NULL, canivt.data_cache = NULL)
  expect_false(ivt_cache_is_set("ivt"))
  expect_false(ivt_cache_is_set("data"))
  expect_match(ivt_cache_dir("ivt", create = FALSE), "canivt_ivt_cache$")
  expect_match(ivt_cache_dir("data", create = FALSE), "canivt_data_cache$")
})

test_that("ivt_cache_dir uses the option when set, and creates the directory", {
  d <- file.path(tempdir(), "canivt_test_cache_opt")
  unlink(d, recursive = TRUE)
  withr::local_options(canivt.data_cache = d)
  expect_true(ivt_cache_is_set("data"))
  got <- ivt_cache_dir("data")
  expect_equal(normalizePath(got), normalizePath(d))
  expect_true(dir.exists(got))
})

test_that(".onLoad seeds options from CANIVT_* env vars without overriding set options", {
  # `.onLoad` / `.onAttach` are internal (unexported); reference them through the
  # namespace so this resolves regardless of how the suite is invoked (bare names
  # only resolve when the test body happens to run inside the package namespace,
  # e.g. devtools::test(), but not under test_dir()/single-file runs).
  onLoad <- canivt:::.onLoad
  # env var seeds an unset option
  withr::local_options(canivt.ivt_cache = NULL)
  withr::local_envvar(CANIVT_IVT_CACHE = "/tmp/from-renviron")
  onLoad(NULL, "canivt")
  expect_equal(getOption("canivt.ivt_cache"), "/tmp/from-renviron")

  # but an explicitly set option wins over the env var
  withr::local_options(canivt.data_cache = "/tmp/from-option")
  withr::local_envvar(CANIVT_DATA_CACHE = "/tmp/from-renviron")
  onLoad(NULL, "canivt")
  expect_equal(getOption("canivt.data_cache"), "/tmp/from-option")
})

test_that(".onAttach warns only when the data cache is not set", {
  onAttach <- canivt:::.onAttach
  withr::local_options(canivt.data_cache = NULL)
  expect_message(onAttach(NULL, "canivt"), "canivt.data_cache")

  withr::local_options(canivt.data_cache = file.path(tempdir(), "set"))
  expect_silent(onAttach(NULL, "canivt"))
})
