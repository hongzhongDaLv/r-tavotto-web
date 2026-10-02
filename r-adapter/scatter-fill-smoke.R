library(ggplot2)
if(.Platform$OS.type=='windows')Sys.setlocale('LC_CTYPE','English_United States.UTF8')
`%||%` <- function(x,y)if(is.null(x))y else x
source('r-adapter/visual-properties.R',encoding='UTF-8')
d <- data.frame(x=c(1,1,2,2),y=c(2,3,4,5),g=factor(c('A','A','B','B')))
base <- ggplot(d,aes(x,y,colour=g))+geom_point(shape=19,size=3)
before <- ggplot_build(base)
marker <- list(gid='point-group-1-1',prop='marker',value='o')
after <- apply_point_groups(before,list(marker))
a <- before$data[[1]]$group==1
b <- before$data[[1]]$group==2
stopifnot(all(after$data[[1]]$fill[a]==before$data[[1]]$colour[a]),
          identical(as.character(after$data[[1]]$fill[b]),as.character(before$data[[1]]$fill[b])),all(after$data[[1]]$shape[a]==21))
mapped <- ggplot(d,aes(x,y,colour=g,fill=g))+geom_point(shape=19)+
  scale_fill_manual(values=c(A=NA,B='#123456'))
mapped_before <- ggplot_build(mapped)
mapped_after <- apply_point_groups(mapped_before,list(marker))
stopifnot(all(mapped_after$data[[1]]$fill[a]==mapped_before$data[[1]]$colour[a]),
          identical(mapped_after$data[[1]]$fill[b],mapped_before$data[[1]]$fill[b]))
empty <- list(gid=marker$gid,prop='facecolor',value=NA_character_)
custom <- list(gid=marker$gid,prop='facecolor',value='#aabbcc')
for(patches in list(list(empty,marker),list(marker,empty)))
  stopifnot(all(is.na(apply_point_groups(before,patches)$data[[1]]$fill[a])))
for(patches in list(list(custom,marker),list(marker,custom)))
  stopifnot(all(apply_point_groups(before,patches)$data[[1]]$fill[a]=='#aabbcc'))
na_source <- ggplot(d,aes(x,y,colour=g))+geom_point(shape=19,fill=NA)
parent <- ggplot_build(apply_visual_property(unserialize(serialize(na_source,NULL)),'layer-1','marker','o'))
stopifnot(all(parent$data[[1]]$fill==parent$data[[1]]$colour))
preserved_empty <- ggplot_build(apply_visual_property(unserialize(serialize(na_source,NULL)),'layer-1','marker','o',preserve_empty_fill=TRUE))
stopifnot(all(is.na(preserved_empty$data[[1]]$fill)))
filled_source <- ggplot(d,aes(x,y,colour=g))+geom_point(shape=21,fill='#aabbcc')
filled_parent <- ggplot_build(apply_visual_property(filled_source,'layer-1','marker','s'))
stopifnot(all(filled_parent$data[[1]]$fill=='#aabbcc'),all(filled_parent$data[[1]]$shape==22))
cat('SCATTER_FILL_PASS: group, NA-mapped, explicit empty/custom order, parent NA, existing fill\n')
