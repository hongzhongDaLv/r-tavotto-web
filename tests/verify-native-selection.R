# Real ggplot rendering regression: unsplit visible artists remain selectable,
# while semantic parents yield canvas selection to the children actually made.
args <- commandArgs(TRUE)
adapter <- normalizePath(args[[1]], winslash='/')
report_file <- if(length(args)>1L)args[[2L]] else file.path(dirname(adapter),'tests','native-selection-verification.json')
engine <- new.env(parent=globalenv())
definitions <- parse(file.path(adapter,'engine.R'),encoding='UTF-8')
# Load the exact engine definitions without entering its JSON-lines stdin loop.
for(expression in definitions) {
  if(is.call(expression)&&identical(expression[[1L]],as.name('<-'))&&identical(expression[[2L]],as.name('input')))break
  eval(expression,envir=engine)
}
scratch <- tempfile('tavotto-selection-')
dir.create(scratch,recursive=TRUE)
base_code <- c('library(ggplot2)',
  'd <- data.frame(x=c(1,2,3,4),y=c(2,5,3,6),group=factor(c("a","a","b","b")))',
  'tavotto_layout <- list(size_mm=c(120,100),frame_mm=c(20,15,80,60))')
cases <- list(
  point='tavotto_plot <- ggplot(d,aes(x,y)) + geom_point(colour="#377EB8",size=2)',
  col='tavotto_plot <- ggplot(d,aes(factor(x),y)) + geom_col(fill="#377EB8")',
  line='tavotto_plot <- ggplot(d,aes(x,y)) + geom_line(colour="#377EB8")',
  vline='tavotto_plot <- ggplot(d,aes(x,y)) + geom_vline(xintercept=2.5)',
  errorbar='tavotto_plot <- ggplot(d,aes(x,y)) + geom_errorbar(aes(ymin=y-1,ymax=y+1),width=.2)',
  point_groups='tavotto_plot <- ggplot(d,aes(x,y,colour=group)) + geom_point(size=2)',
  col_groups='tavotto_plot <- ggplot(d,aes(factor(x),y,fill=group)) + geom_col()',
  errorbar_reused_series='tavotto_plot <- ggplot(d,aes(factor(x),y,group=group)) + geom_errorbar(aes(ymin=y-1,ymax=y+1),width=.2)',
  errorbar_groups='tavotto_plot <- ggplot(d,aes(factor(x),y)) + geom_errorbar(aes(ymin=y-1,ymax=y+1),width=.2)',
  text_groups='tavotto_plot <- ggplot(d,aes(x,y,label=group)) + geom_text()')
checks <- list()
for(name in names(cases)) {
  script <- file.path(scratch,paste0(name,'.R'))
  writeLines(c(base_code,cases[[name]]),script,useBytes=TRUE)
  result <- engine$handle(list(method='open',script=script,object='tavotto_plot',out=file.path(scratch,name)))
  elements <- result$manifest$elements
  layer <- Filter(function(element)identical(element$gid,'layer-1'),elements)
  stopifnot(length(layer)==1L)
  layer <- layer[[1L]]
  leaves <- Filter(function(element)grepl('^(point|fill|errorbar|text)-group-1-',element$gid),elements)
  grouped <- endsWith(name,'_groups')
  if(!identical(layer$canvas_selectable,!grouped))stop(name, ': parent selectable=',
    layer$canvas_selectable, ', actual leaves=',length(leaves))
  if(grouped) {
    stopifnot(length(leaves)>=2L,all(vapply(leaves,function(element)isTRUE(element$canvas_selectable),logical(1))))
    if(name!='text_groups')stopifnot(all(vapply(leaves,function(element)length(element$geometry$paths)>0L,logical(1))))
  } else {
    stopifnot(!length(leaves),length(layer$geometry$paths)>0L)
    all_points <- do.call(rbind,lapply(layer$geometry$paths,function(path)
      do.call(rbind,lapply(path$points,function(point)as.numeric(unlist(point))))))
    stopifnot(all(is.finite(all_points)))
    if(name=='point')stopifnot(length(layer$geometry$paths)==nrow(engine$state$p$data))
    if(name=='col')stopifnot(length(layer$geometry$paths)==nrow(engine$state$p$data))
    if(name=='line')stopifnot(!isTRUE(layer$geometry$fill),length(layer$geometry$paths)==1L,
      length(layer$geometry$paths[[1L]]$points)==4L)
    if(name=='vline')stopifnot(!isTRUE(layer$geometry$fill),
      abs(all_points[1L,1L]-all_points[2L,1L])<1e-9)
  }
  checks[[name]] <- list(selectable=layer$canvas_selectable,leaf_count=length(leaves),
    parent_path_count=length(layer$geometry$paths),parent_bbox=layer$bbox)
}
dir.create(dirname(report_file),recursive=TRUE,showWarnings=FALSE)
jsonlite::write_json(list(status='PASS',r_version=as.character(getRversion()),
  ggplot2_version=as.character(packageVersion('ggplot2')),checks=checks),report_file,auto_unbox=TRUE,pretty=TRUE)
if(length(args)>2L) {
  # Frontend's mounted tests consume these actual R-generated hit geometries.
  scene_script <- file.path(scratch,'cad_scene.R')
  writeLines(c(base_code,
    'tavotto_plot <- ggplot(d,aes(factor(x),y)) + geom_col(aes(fill=group)) + geom_errorbar(aes(ymin=y-1,ymax=y+1),width=.2) + geom_point(aes(colour=group),size=2)'),scene_script)
  scene <- engine$handle(list(method='open',script=scene_script,object='tavotto_plot',out=file.path(scratch,'cad_scene')))
  scene$manifest$elements <- lapply(Filter(function(element)
    element$gid=='figure'||element$role=='axes'||startsWith(element$gid,'layer-')||
      grepl('^(point|fill|errorbar)-group-',element$gid),scene$manifest$elements),function(element) {
        element$editable <- list(); element$source_script <- NULL; element
      })
  scene$manifest$source_script <- NULL
  dir.create(dirname(args[[3L]]),recursive=TRUE,showWarnings=FALSE)
  jsonlite::write_json(scene$manifest,args[[3L]],auto_unbox=TRUE,pretty=TRUE,digits=10)
}
cat('NATIVE_LAYER_SELECTION_PASS\n',normalizePath(report_file,winslash='/'), '\n')
