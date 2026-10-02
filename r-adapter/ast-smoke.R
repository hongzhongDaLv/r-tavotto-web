# Regression gate for parsed-copy transformations; no user project is executed.
if (.Platform$OS.type=='windows') Sys.setlocale('LC_CTYPE','English_United States.utf8')
options(tavotto.browser=TRUE, tavotto.engine.base=normalizePath('r-adapter'))
source('r-adapter/engine.R', encoding='UTF-8')
fixture <- tempfile(fileext='.R')
writeLines(c(
  "make_plot <- function() {",
  "  values <- matrix(1:4, nrow=2)",
  "  selected <- values[, 1]",
  "  nothing <- list(NULL, value=NULL)",
  "  stopifnot(identical(nothing[[1]], NULL), identical(nothing$value, NULL))",
  "  p <- ggplot(data.frame(x=1:2, y=selected),aes(x,y)) + geom_point() + labs(title=NULL)",
  "  ggsave('fixture.pdf', p, width=5, height=4)",
  "}",
  "make_plot()"
), fixture)
state$out <- tempdir()
transformed <- source_page_geometry(fixture, tempdir())
evaluation <- new.env(parent=globalenv())
evaluation$exported <- NULL
evaluation$tavotto_browser_graphics_export <- function(.name, ...) {
  stopifnot(identical(.name, 'ggsave'))
  evaluation$exported <- list(...)
  invisible(NULL)
}
eval(transformed$expressions, envir=evaluation)
stopifnot(length(formals(evaluation$make_plot))==0L,
          inherits(evaluation$exported$plot %||% evaluation$exported[[2L]],'ggplot'),
          identical(evaluation$exported$width,5),identical(evaluation$exported$height,4))
unlink(fixture)
cat('AST_COPY_NULL_AND_MISSING_PASS\n')
