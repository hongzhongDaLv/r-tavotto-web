# Export must execute in a fresh R process, without the live engine's globals.
if (.Platform$OS.type=='windows') Sys.setlocale('LC_CTYPE','English_United States.utf8')
test_lib<-Sys.getenv('TAVOTTO_NATIVE_TEST_LIB')
if(nzchar(test_lib)).libPaths(c(test_lib,.libPaths()))
options(tavotto.browser=TRUE,tavotto.engine.base=normalizePath('r-adapter'))
source('r-adapter/engine.R',encoding='UTF-8')
fixture_dir<-tempfile('replay-smoke-');dir.create(fixture_dir)
fixture<-file.path(fixture_dir,'fixture.R')
writeLines(c('library(ggplot2)',
  'p <- ggplot(data.frame(x=1:3,y=1:3),aes(x,y))+geom_point(shape=19,colour="#59844B",size=3)+theme_classic()',
  'ggsave("source.pdf",p,width=480,height=320,units="px",dpi=96)'),fixture)
opened<-handle(list(method='open',script=fixture,out=file.path(fixture_dir,'outputs')))
stopifnot(isTRUE(opened$ok))
edited<-handle(list(method='apply',patches=list(list(gid='layer-1',prop='marker',value='o'))))
stopifnot(isTRUE(edited$ok))
export_figure(generate_files=FALSE)
replay<-normalizePath(file.path(fixture_dir,'outputs','figure-edited.R'),winslash='/')
writeLines(c(readLines(replay,encoding='UTF-8'),
  'stopifnot(identical(built$data[[1]]$shape,rep(21,3)),identical(built$data[[1]]$fill,rep("#59844B",3)))',
  'cat("FRESH_R_REPLAY_PASS\\n")'),replay,useBytes=TRUE)
command<-file.path(R.home('bin'),'Rscript.exe')
if(!file.exists(command))command<-file.path(R.home('bin'),'Rscript')
output<-system2(command,c('-e',shQuote(paste0('Sys.setlocale("LC_CTYPE","English_United States.utf8");source(',dQuote(replay),',encoding="UTF-8")'))),stdout=TRUE,stderr=TRUE)
cat(paste(output,collapse='\n'),'\n')
stopifnot(is.null(attr(output,'status')),any(grepl('FRESH_R_REPLAY_PASS',output,fixed=TRUE)),
          file.exists(file.path(fixture_dir,'figure-replayed.svg')),
          file.size(file.path(fixture_dir,'figure-replayed.svg'))>1000)
unlink(fixture_dir,recursive=TRUE)
