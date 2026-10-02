# R engine for the Tavotto derivative. AGPL-3.0-only, 2026-09-22.
# JSON-lines transport; the plot is sourced once and retained in this process.
args <- commandArgs(TRUE)
browser_mode <- isTRUE(getOption('tavotto.browser', FALSE))
base <- normalizePath(if(browser_mode)getOption('tavotto.engine.base') else args[[1]], winslash='/')
# UTF-8 is part of the worker protocol: scientific labels commonly contain
# superscripts, Greek symbols, and non-English text. Windows otherwise inherits
# a POSIX `C.UTF-8` name it cannot use and silently corrupts source/JSON text.
if(.Platform$OS.type=='windows')invisible(try(Sys.setlocale('LC_CTYPE','English_United States.utf8'),silent=TRUE))
options(encoding='UTF-8')
.libPaths(c(file.path(base,'lib'), .libPaths()))
suppressPackageStartupMessages({library(ggplot2); library(jsonlite); library(grid)})
source(file.path(base,'visual-properties.R'),encoding='UTF-8')
`%||%` <- function(a,b) if(is.null(a)) b else a
state <- new.env(); state$rev <- 0L
literal <- r_native_expression
# Keep page geometry tied to explicit R export calls. Physical axes geometry is
# measured from the selected plot's actual source device/composite, never fitted
# back from the page dimensions.
PAGE_SIZE_MAX_MM <- 1000
ast_walk <- function(x, visit) {
  if (is.call(x)) {
    visit(x)
    if (length(x) > 1L) for (i in seq.int(2L, length(x))) {
      tryCatch(ast_walk(x[[i]], visit), error=function(e) invisible(NULL))
    }
  } else if (is.expression(x) || is.list(x)) {
    for (i in seq_along(x)) {
      tryCatch(ast_walk(x[[i]], visit), error=function(e) invisible(NULL))
    }
  }
  invisible(NULL)
}
call_name <- function(x) {
  if (!is.call(x)) return('')
  value <- paste(deparse(x[[1L]], width.cutoff=500L), collapse='')
  sub('^.*:::{0,1}', '', value)
}
call_args <- function(x) as.list(x)[-1L]
call_arg <- function(x, name, position=NULL) {
  values <- call_args(x); nms <- names(values)
  if (!is.null(nms) && name %in% nms) return(values[[which(nms == name)[[1L]]]])
  if (!is.null(position) && length(values) >= position) return(values[[position]])
  NULL
}
static_number <- function(x) {
  if (is.numeric(x) && length(x) == 1L && is.finite(x)) return(as.numeric(x))
  if (!is.call(x)) return(NULL)
  op <- as.character(x[[1L]])
  if(length(op)!=1L)return(NULL)
  args <- as.list(x)[-1L]
  if (op %in% c('+','-') && length(args) == 1L) {
    value <- static_number(args[[1L]])
    if (is.null(value)) return(NULL)
    return(if (op == '-') -value else value)
  }
  if (!op %in% c('+','-','*','/','^') || length(args) != 2L) return(NULL)
  a <- static_number(args[[1L]]); b <- static_number(args[[2L]])
  if (is.null(a) || is.null(b)) return(NULL)
  value <- switch(op, '+'=a+b, '-'=a-b, '*'=a*b, '/'=if (b == 0) NA_real_ else a/b,
    '^'=a^b)
  if (length(value) != 1L || !is.finite(value)) NULL else value
}
static_string <- function(x, default=NULL) {
  if (is.null(x)) return(default)
  if (is.character(x) && length(x) == 1L) return(x)
  NULL
}
graphics_device_names <- c('ggsave','svg','pdf','cairo_pdf','png','jpeg','tiff','bmp','postscript')
is_output_dir_path <- function(x) {
  is.call(x) && call_name(x) == 'file.path' && length(x) >= 2L && identical(x[[2L]], as.name('output_dir'))
}
source_export_geometry <- function(expressions, require_output_dir=TRUE) {
  writes <- list()
  ast_walk(expressions, function(node) {
    if (call_name(node) %in% graphics_device_names) writes[[length(writes)+1L]] <<- node
  })
  if (!length(writes)) return(NULL)
  top_output_dir <- which(vapply(as.list(expressions), function(node) {
    is.call(node) && length(node) >= 3L && is.symbol(node[[1L]]) && as.character(node[[1L]]) %in% c('<-','=') &&
      is.symbol(node[[2L]]) && identical(as.character(node[[2L]]), 'output_dir')
  }, logical(1)))
  if (isTRUE(require_output_dir)) {
    if (length(top_output_dir) != 1L) stop('Safe source open requires exactly one top-level output_dir assignment for graphics exports')
    for (node in writes) {
      path <- call_arg(node, 'filename', 1L)
      if (is.null(path)) path <- call_arg(node, 'file', 1L)
      if (!is_output_dir_path(path)) stop('Refusing to run a source script whose graphics output path is not derived from output_dir: ', paste(deparse(node[[1L]]), collapse=''))
    }
  }
  mm <- lapply(writes, function(node) {
    name <- call_name(node)
    width <- static_number(call_arg(node, 'width'))
    height <- static_number(call_arg(node, 'height'))
    if (is.null(width) || is.null(height) || width <= 0 || height <= 0) {
      stop('Cannot derive the source export size from explicit numeric width/height in ', name, '()')
    }
    units <- static_string(call_arg(node, 'units'), if (name == 'ggsave') 'in' else if (name %in% c('png','jpeg','tiff','bmp')) 'px' else 'in')
    if (is.null(units)) stop('Cannot derive the source export size: units must be a literal string')
    factor <- switch(tolower(units), `in`=25.4, inch=25.4, inches=25.4, cm=10, mm=1,
      px={
        dpi <- static_number(call_arg(node, if(name=='ggsave')'dpi' else 'res'))
        if (is.null(dpi) || dpi <= 0) stop('Pixel-sized graphics exports need an explicit numeric res= to derive physical page size')
        25.4/dpi
      }, stop('Unsupported graphics export unit: ', units))
    c(width*factor, height*factor)
  })
  reference <- mm[[1L]]
  if (any(vapply(mm, function(value) length(value) != 2L || any(abs(value-reference) > 1e-6), logical(1)))) {
    stop('Graphics export devices declare conflicting page sizes; refusing to invent a single initial canvas size')
  }
  list(size_mm=reference, output_dir_index=if(length(top_output_dir)==1L)top_output_dir[[1L]] else NULL, output_count=length(writes))
}
source_export_size_from_file <- function(script) {
  expressions <- tryCatch(parse(script, encoding='UTF-8'), error=function(e) stop('Cannot parse recorded source script for page dimensions: ', conditionMessage(e)))
  geometry <- source_export_geometry(expressions, require_output_dir=FALSE)
  geometry$size_mm %||% NULL
}
cached_render_geometry <- function(provenance) {
  if(!is.list(provenance)||!identical(provenance$mode,'cached_render_state'))return(NULL)
  path<-provenance$render_state
  if(!is.character(path)||length(path)!=1L||!nzchar(path)||!file.exists(path))return(NULL)
  cached<-tryCatch(readRDS(path),error=function(e)stop('Cannot read the selected cached figure metadata: ',conditionMessage(e)))
  meta<-cached$meta %||% list()
  number<-function(x) {
    value<-suppressWarnings(as.numeric(unlist(x,use.names=FALSE)))
    if(!length(value)||any(!is.finite(value)))NULL else value
  }
  csv_path<-sub('_render_state\\.rds$','_geometry.csv',path)
  geometry<-if(file.exists(csv_path))tryCatch(read.csv(csv_path,check.names=FALSE,stringsAsFactors=FALSE),error=function(e)NULL) else NULL
  row<-if(!is.null(geometry)&&nrow(geometry)==1L)geometry[1,,drop=FALSE] else NULL
  csv_num<-function(name)if(!is.null(row)&&name%in%names(row))number(row[[name]]) else NULL
  meta_num<-function(name)if(is.list(meta))number(meta[[name]]) else NULL

  page<-number(meta$size_mm %||% meta$canvas_size_mm)
  if(is.null(page)||length(page)!=2L) {
    wh<-c(meta_num('width_mm'),meta_num('height_mm'))
    if(length(wh)==2L&&!any(vapply(wh,is.null,logical(1))))page<-unlist(wh,use.names=FALSE)
  }
  if(is.null(page)||length(page)!=2L)page<-c(csv_num('width_mm'),csv_num('height_mm'))
  if(length(page)!=2L||any(!is.finite(page))||any(page<=0))page<-NULL

  frame<-number(meta$frame_mm %||% meta$layout$frame_mm)
  if(!is.null(frame)&&length(frame)==4L&&all(frame[3:4]>0))return(list(page_mm=page,frame_mm=frame))

  left<-meta_num('left_mm');top<-meta_num('top_mm')
  if(is.null(left))left<-csv_num('left_mm')
  if(is.null(top))top<-csv_num('top_mm')
  frame_w<-meta_num('frame_width_mm');frame_h<-meta_num('frame_height_mm')
  scalar_frame<-number(meta$frame_mm)
  if(length(scalar_frame)==1L)frame_w<-frame_h<-scalar_frame
  if(is.null(frame_w))frame_w<-csv_num('frame_width_mm')
  if(is.null(frame_h))frame_h<-csv_num('frame_height_mm')
  if(is.null(frame_w)||is.null(frame_h)) {
    g<-cached$gtable
    if(!is.null(g$layout)&&!is.null(g$widths)&&!is.null(g$heights)) {
      cells<-which(g$layout$name=='panel')
      if(length(cells)==1L) {
        cell<-g$layout[cells,,drop=FALSE]
        device<-tempfile('cached-frame-measure-',tmpdir=dirname(path),fileext='.pdf')
        grDevices::cairo_pdf(device,width=(page %||% c(100,100))[[1L]]/25.4,
          height=(page %||% c(100,100))[[2L]]/25.4)
        dev<-grDevices::dev.cur()
        measured<-tryCatch(c(
          grid::convertWidth(g$widths[cell$l],'mm',valueOnly=TRUE),
          grid::convertHeight(g$heights[cell$t],'mm',valueOnly=TRUE)),error=function(e)NULL)
        if(grDevices::dev.cur()==dev)grDevices::dev.off()
        unlink(device)
        if(length(measured)==2L&&all(is.finite(measured))&&all(measured>0)) {
          frame_w<-measured[[1L]];frame_h<-measured[[2L]]
        }
      }
    }
  }
  if(is.null(left))left<-csv_num('left_mm')
  if(is.null(top))top<-csv_num('top_mm')
  if(is.null(frame_w))frame_w<-csv_num('frame_mm')
  if(is.null(frame_h))frame_h<-csv_num('frame_mm')
  if(length(left)==1L&&length(top)==1L&&length(frame_w)==1L&&length(frame_h)==1L&&
     all(is.finite(c(left,top,frame_w,frame_h)))&&all(c(frame_w,frame_h)>0))
    frame<-c(left,top,frame_w,frame_h)
  list(page_mm=page,frame_mm=frame)
}
source_page_geometry <- function(script, out) {
  expressions <- tryCatch(parse(script, encoding='UTF-8'), error=function(e) stop('Cannot parse source R script: ', conditionMessage(e)))
  if(browser_mode) {
    # The browser owns a virtual filesystem. Redirect export paths in the parsed
    # copy and record evaluated device arguments (including variables and px/dpi).
    # Uploaded source bytes are never changed or queried through a host path.
    state$browser_exports <- list()
    wrap_exports <- function(node) {
      if(!is.call(node))return(node)
      name<-call_name(node)
      if(name=='install.packages')return(quote(invisible(NULL)))
      if(name%in%graphics_device_names) {
        node[[1L]]<-as.name('tavotto_browser_graphics_export')
        return(as.call(c(as.list(node)[1L],list(.name=name),as.list(node)[-1L])))
      }
      parts<-as.list(node)
      if(length(parts)>1L)for(i in seq.int(2L,length(parts))) {
        # Missing index arguments (data[, 1]) and function formals must remain
        # missing. Binding that sentinel to a local variable makes the local
        # variable itself unreadable, even when the subscript did not throw.
        # Single-bracket list assignment also preserves real NULL arguments:
        # node[[i]] <- NULL would remove a function()'s empty formal pairlist.
        if(!identical(parts[[i]],quote(expr=)))parts[i]<-list(wrap_exports(parts[[i]]))
      }
      as.call(parts)
    }
    return(list(expressions=as.expression(lapply(as.list(expressions),wrap_exports)),size_mm=NULL))
  }
  geometry <- source_export_geometry(expressions)
  if (!is.null(geometry)) {
    # Change only the literal assignment's RHS in the parsed copy. The source
    # bytes on disk remain untouched; all recognized graphics exports now land
    # inside this session directory.
    target <- expressions[[geometry$output_dir_index]]
    target[[3L]] <- normalizePath(out, winslash='/', mustWork=FALSE)
    expressions[[geometry$output_dir_index]] <- target
  }
  namespaced_install <- FALSE
  ast_walk(expressions, function(node) {
    head <- if(is.call(node))node[[1L]] else NULL
    if(is.call(head)&&is.symbol(head[[1L]])&&as.character(head[[1L]])%in%c('::',':::')&&length(head)>=3L&&
       is.symbol(head[[3L]])&&identical(as.character(head[[3L]]),'install.packages'))namespaced_install <<- TRUE
  })
  if(namespaced_install)stop('Refusing to run a source script that bypasses the installation guard with utils::install.packages')
  block_install_calls <- function(node) {
    if(!is.call(node))return(node)
    if(is.symbol(node[[1L]])&&identical(as.character(node[[1L]]),'install.packages'))
      return(quote(stop('Automatic package installation is disabled while opening a source script; install dependencies explicitly and reopen')))
    parts<-as.list(node)
    if(length(parts)>1L)for(i in seq.int(2L,length(parts))) {
      if(!identical(parts[[i]],quote(expr=)))parts[i]<-list(block_install_calls(parts[[i]]))
    }
    as.call(parts)
  }
  expressions <- as.expression(lapply(as.list(expressions),block_install_calls))
  list(expressions=expressions, size_mm=geometry$size_mm %||% NULL)
}
tavotto_browser_graphics_export <- function(.name, ...) {
  fun<-if(.name=='ggsave')ggplot2::ggsave else get(.name,envir=asNamespace('grDevices'))
  values<-list(...)
  # Match positional arguments using the native function's formal order.
  nms<-names(values) %||% rep('',length(values));used<-nms[nzchar(nms)]
  remaining<-setdiff(names(formals(fun)),c(used,'...'));index<-1L
  for(i in seq_along(values))if(!nzchar(nms[[i]])) {
    if(index<=length(remaining)){nms[[i]]<-remaining[[index]];index<-index+1L}
  }
  names(values)<-nms
  number<-function(x)if(is.numeric(x)&&length(x)==1L&&is.finite(x)&&x>0)as.numeric(x) else NULL
  w<-number(values$width);h<-number(values$height)
  units<-values$units %||% if(.name=='ggsave')'in' else if(.name%in%c('png','jpeg','tiff','bmp'))'px' else 'in'
  dpi<-if(.name=='ggsave')values$dpi %||% 300 else values$res
  if(is.character(dpi))dpi<-switch(dpi,screen=72,print=300,retina=320,NA_real_)
  factor<-switch(tolower(units),`in`=25.4,inch=25.4,inches=25.4,cm=10,mm=1,px=if(!is.null(number(dpi)))25.4/dpi else NA_real_,NA_real_)
  size<-if(!is.null(w)&&!is.null(h)&&is.finite(factor))c(w,h)*factor else NULL
  event<-list(size_mm=size,plot=if(.name=='ggsave')values$plot %||% ggplot2::last_plot() else NULL,
    filename=values[[if(.name=='ggsave')'filename' else 'file']] %||% .name)
  state$browser_exports[[length(state$browser_exports)+1L]]<-event
  path_key<-if(.name=='ggsave')'filename' else if(.name%in%c('png','jpeg','tiff','bmp'))'filename' else 'file'
  filename<-values[[path_key]] %||% paste0(.name,'-',length(state$browser_exports),if(.name=='ggsave')'.pdf' else paste0('.',.name))
  values[[path_key]]<-file.path(state$out,paste0('source-',length(state$browser_exports),'-',basename(filename)))
  if(.name=='ggsave')values$path<-NULL
  # Exports remain real native R exports in the virtual filesystem.
  do.call(fun,values)
}
browser_export_size <- function(plot) {
  state$browser_size_conflict<-FALSE
  events<-state$browser_exports %||% list()
  selected<-Filter(function(x)!is.null(x$plot)&&identical(x$plot,plot),events)
  if(!length(selected))selected<-Filter(function(x)is.null(x$plot),events)
  sizes<-Filter(Negate(is.null),lapply(selected,function(x)x$size_mm))
  if(!length(sizes))return(NULL)
  reference<-sizes[[1L]]
  if(any(vapply(sizes,function(value)any(abs(value-reference)>1e-6),logical(1)))) {
    state$browser_size_conflict<-TRUE
    return(NULL)
  }
  reference
}
source_patchwork_selector <- function(expressions, object_name) {
  top <- as.list(expressions)
  is_assignment <- function(node, name=NULL) is.call(node) && length(node)>=3L &&
    is.symbol(node[[1L]]) && as.character(node[[1L]]) %in% c('<-','=') &&
    is.symbol(node[[2L]]) && (is.null(name)||identical(as.character(node[[2L]]),name))
  selected <- Filter(function(node)is_assignment(node,object_name),top)
  if(length(selected)!=1L)return(NULL)
  rhs<-selected[[1L]][[3L]]
  if(!is.call(rhs)||!call_name(rhs)%in%c('[','[[')||!is.symbol(rhs[[2L]])||length(rhs)<3L)return(NULL)
  source_list<-rhs[[2L]];index<-static_number(rhs[[3L]])
  if(is.null(index)||index<1||index!=as.integer(index))return(NULL)
  composites<-Filter(function(node) {
    if(!is_assignment(node)||!is.call(node[[3L]])||call_name(node[[3L]])!='wrap_plots')return(FALSE)
    input<-call_arg(node[[3L]],'plots',1L)
    is.symbol(input)&&identical(input,source_list)
  },top)
  if(length(composites)!=1L)return(NULL)
  list(name=as.character(composites[[1L]][[2L]]),index=as.integer(index),source_list=as.character(source_list))
}
measure_patchwork_panel <- function(plot, env, page_mm, expressions, object_name) {
  selector<-source_patchwork_selector(expressions,object_name)
  patchwork_names<-Filter(function(name)tryCatch(inherits(get(name,envir=env,inherits=FALSE),'patchwork'),error=function(e)FALSE),ls(env,all.names=TRUE))
  if(is.null(selector)) {
    if(length(patchwork_names))stop('Cannot map the selected ggplot to one source patchwork cell from the R assignments; refusing to use an isolated-plot frame')
    return(NULL)
  }
  composite<-get(selector$name,envir=env,inherits=FALSE)
  if(!inherits(composite,'patchwork'))stop('The source composition assignment is not a patchwork object')
  if (!requireNamespace('patchwork', quietly=TRUE)) stop('The source uses patchwork but patchwork is unavailable for source-frame measurement')
  page <- composite
  index <- selector$index
  g <- patchwork::patchworkGrob(page)
  # patchwork versions use either a concise `panel-<plot-index>` name or the
  # expanded `panel; ...-<plot-index>` name. Match only those panel cells.
  candidates <- grep(paste0('^(panel-',index,'|panel;.*-',index,')$'), g$layout$name)
  if (length(candidates) != 1L) stop('The selected patchwork panel has no unique gtable cell; refusing to substitute an isolated-plot frame')
  outer <- g$grobs[[candidates[[1L]]]]
  nested_viewport <- if(!is.null(outer$grobs)&&length(outer$grobs))outer$grobs[[1L]]$vp else NULL
  panel_viewport <- nested_viewport %||% outer$vp
  if(is.null(panel_viewport))stop('The selected patchwork panel viewport cannot be measured safely')
  recording <- new.env(parent=emptyenv())
  probe <- grid::grob(name='tavotto-source-panel-probe', recording_env=recording,
    vp=panel_viewport, cl='tavottoMeasureProbe')
  if(!is.null(nested_viewport))outer$grobs[[1L]] <- probe else outer <- probe
  g$grobs[[candidates[[1L]]]] <- outer
  file <- tempfile('source-patchwork-frame-', tmpdir=out_dir_from_state(), fileext='.pdf')
  on.exit(unlink(file), add=TRUE)
  grDevices::cairo_pdf(file, width=page_mm[[1L]]/25.4, height=page_mm[[2L]]/25.4)
  device <- grDevices::dev.cur()
  on.exit(if (grDevices::dev.cur() == device) grDevices::dev.off(), add=TRUE)
  grid::grid.newpage(); grid::grid.draw(g); grid::grid.force()
  frame <- recording$frame
  grDevices::dev.off()
  if (is.null(frame) || length(frame) != 4L || any(!is.finite(frame)) || any(frame[3:4] <= 0)) {
    stop('Could not measure the selected panel in the full source patchwork device')
  }
  frame
}
out_dir_from_state <- function() state$out
drawDetails.tavottoMeasureProbe <- function(x, ...) {
  a <- grid::deviceLoc(grid::unit(0,'npc'), grid::unit(0,'npc'), valueOnly=TRUE)
  b <- grid::deviceLoc(grid::unit(1,'npc'), grid::unit(1,'npc'), valueOnly=TRUE)
  height_in <- grDevices::dev.size('in')[[2L]]
  assign('frame', c(a$x*25.4, (height_in-b$y)*25.4,
    (b$x-a$x)*25.4, (b$y-a$y)*25.4), envir=x$recording_env)
}
# Physical panel layout is independent from the output device size.
draw_figure <- function(g, w, h, frame=NULL) {
  grid.newpage()
  pan<-g$layout[g$layout$name=='panel',]
  if(nrow(pan)!=1)stop('This first R adapter supports one ggplot panel')
  if(is.null(frame)) {grid.draw(g);return(invisible(NULL))}
  g$widths[pan$l]<-unit(frame[3],'mm');g$heights[pan$t]<-unit(frame[4],'mm')
  bw<-convertWidth(sum(g$widths[seq_len(pan$l-1)]),'mm',valueOnly=TRUE)
  bh<-convertHeight(sum(g$heights[seq_len(pan$t-1)]),'mm',valueOnly=TRUE)
  tw<-convertWidth(sum(g$widths),'mm',valueOnly=TRUE)
  th<-convertHeight(sum(g$heights),'mm',valueOnly=TRUE)
  if(!is.null(attr(frame,'metrics'))) {
    m<-attr(frame,'metrics');bw<-m[1];bh<-m[2];tw<-m[3];th<-m[4]
  }
  pushViewport(viewport(x=unit(frame[1]-bw,'mm'),y=unit(h-frame[2]+bh,'mm'),
    width=unit(tw,'mm'),height=unit(th,'mm'),just=c('left','top')))
  grid.draw(g);popViewport()
}
move_grob <- function(g, i, dx, dy) {
  g$grobs[[i]] <- grobTree(g$grobs[[i]], vp=viewport(x=unit(.5,'npc')+unit(dx,'mm'),y=unit(.5,'npc')-unit(dy,'mm'),clip='off'))
  g$layout$clip[[i]] <- 'off'; g
}
move_element <- function(g, gid, dx, dy) {
  if(startsWith(gid,'layer-')) {
    i<-which(g$layout$name=='panel');j<-as.integer(sub('layer-','',gid))+2L
    g$grobs[[i]]$children[[j]]<-grobTree(g$grobs[[i]]$children[[j]],vp=viewport(x=unit(.5,'npc')+unit(dx,'mm'),y=unit(.5,'npc')-unit(dy,'mm'),clip='off'))
    g
  } else move_grob(g,which(g$layout$name==gid),dx,dy)
}
hide_element <- function(g,gid) {
  if(startsWith(gid,'layer-')) {
    i<-which(g$layout$name=='panel');j<-as.integer(sub('layer-','',gid))+2L
    g$grobs[[i]]$children[[j]]<-nullGrob()
  } else g$grobs[[which(g$layout$name==gid)]]<-nullGrob()
  g
}
apply_plot <- function(p, patches) {
  p <- unserialize(serialize(p,NULL))
  labels <- c(title='title',subtitle='subtitle',caption='caption','xlab-b'='x','ylab-l'='y')
  themes <- c(title='plot.title',subtitle='plot.subtitle',caption='plot.caption','xlab-b'='axis.title.x','ylab-l'='axis.title.y','axis-b'='axis.text.x','axis-l'='axis.text.y')
  for(a in patches) {
    id<-a$gid; prop<-a$prop; v<-a$value
    tick_label_text<-grepl('^axis-[bl][.]tick-label-[0-9]+$',id)&&prop=='text'
    if(grepl('^axis-[bl][.]tick-label-[0-9]+$',id)&&!tick_label_text)id<-sub('[.]tick-label-[0-9]+$','',id)
    if(prop %in% c('major_step','major_values')) {
      modes<-Filter(function(x)x$gid==id&&x$prop=='major_mode',patches)
      if(length(modes)) {
        mode<-modes[[length(modes)]]$value
        if(mode=='auto'||(mode=='fixed'&&prop=='major_step')||(mode=='step'&&prop=='major_values'))next
      }
    }
    if(startsWith(id,'point-group-')||startsWith(id,'errorbar-group-')||startsWith(id,'text-group-'))next
    explicit_point_fill<-prop=='marker'&&any(vapply(patches,function(change)identical(change$gid,id)&&identical(change$prop,'facecolor'),logical(1)))
    extra<-apply_visual_property(p,id,prop,v,env=state$env,preserve_empty_fill=explicit_point_fill)
    if(!is.null(extra)){p<-extra;next}
    if(id %in% names(labels) && prop=='text') p<-p+do.call(labs,setNames(list(v),labels[[id]]))
    else if(id %in% names(themes) && prop %in% c('fontsize','color','fontweight','rotation','fontfamily')) {
      z<-switch(prop,fontfamily=list(family=v),fontsize=list(size=v),color=list(colour=v),rotation=list(angle=v),fontweight=list(face=if(v=='bold')'bold' else 'plain'))
      p<-p+do.call(theme,setNames(list(do.call(element_text,z)),themes[[id]]))
    } else if(id=='axes_0' && prop %in% c('xlim','ylim')) {
      if(length(v)!=2||unlist(v)[1]>=unlist(v)[2])stop('Axis minimum must be smaller than maximum')
      p$coordinates$limits[[if(prop=='xlim')'x' else 'y']]<-unlist(v)
    } else if(startsWith(id,'layer-') && prop=='bar_width') {
      i<-as.integer(sub('layer-','',id));p$layers[[i]]$geom_params$width<-v
    } else if(startsWith(id,'guide-box') && prop=='fontsize') {
      p<-p+theme(legend.text=element_text(size=v),legend.title=element_text(size=v))
    } else if(grepl('^fill-group-[0-9]+-[0-9]+$',id) && prop=='facecolor') {
      sc<-ggplot_build(p)$plot$scales$get_scales('fill');lv<-sc$get_limits();cols<-setNames(sc$map(lv),lv)
      cols[as.integer(sub('^fill-group-[0-9]+-','',id))]<-v;p<-p+scale_fill_manual(values=cols)
    } else if(startsWith(id,'layer-') && prop %in% c('color','linewidth','alpha','markersize','facecolor','text','fontsize','rotation','linestyle')) {
      i<-as.integer(sub('layer-','',id)); key<-switch(prop,color='colour',markersize='size',facecolor='fill',text='label',fontsize='size',rotation='angle',linestyle='linetype',prop)
      if(prop=='fontsize')v<-v/(72.27/25.4)
      if(prop=='linestyle')v<-switch(v,solid='solid',dashed='dashed',dotted='dotted',dashdot='dotdash',v)
      mapped<-!is.null(p$layers[[i]]$mapping[[key]]) || (isTRUE(p$layers[[i]]$inherit.aes)&&!is.null(p$mapping[[key]]))
      if(prop=='facecolor' && mapped && inherits(p$layers[[i]]$geom,'GeomBar')) {
        sc<-ggplot_build(p)$plot$scales$get_scales('fill')
        if(!sc$is_discrete())stop('Continuous fill requires a colour-scale editor')
        lv<-sc$get_limits();p<-p+scale_fill_manual(values=setNames(rep(v,length(lv)),lv))
      } else p$layers[[i]]$aes_params[[key]]<-v
    } else if(!prop %in% c('pos_frac','visible','size_mm','position','frame_mm')) stop('Unsupported property: ',id,'.',prop)
  }; p
}
render <- function(patches=list(), building=FALSE) {
  if(is.null(state$p))stop('Open an R script first')
  # Editing a numeric step/list must activate the matching tick mode in the
  # same transaction; otherwise a visible control could be silently ignored.
  for(id in unique(vapply(Filter(function(a)a$prop%in%c('major_step','major_values'),patches),function(a)a$gid,character(1)))) {
    mode<-Filter(function(a)a$gid==id&&a$prop=='major_mode',patches)
    changes<-Filter(function(a)a$gid==id&&a$prop%in%c('major_step','major_values'),patches)
    if(length(changes)&&(!length(mode)||mode[[length(mode)]]$value=='auto')) {
      last<-changes[[length(changes)]];next_mode<-if(last$prop=='major_step')'step' else 'fixed'
      if(length(mode)) {mode_index<-tail(which(vapply(patches,function(a)a$gid==id&&a$prop=='major_mode',logical(1))),1);patches[[mode_index]]$value<-next_mode}
      else patches[[length(patches)+1L]]<-list(gid=id,prop='major_mode',value=next_mode)
    }
  }
  # Validate against authoritative capabilities, before touching session state.
  if(length(patches))for(a in patches) {
    e<-Filter(function(e)e$gid==a$gid,state$capabilities)
    if(length(e)!=1)stop('Unknown object: ',a$gid)
    f<-Filter(function(f)f$prop==a$prop,e[[1]]$editable)
    # Saved projects created before the physical frame control used a normalized
    # axes position. Keep replay compatibility without exposing that competing
    # fraction-based control in the current inspector.
    if(!length(f)&&identical(a$gid,'axes_0')&&identical(a$prop,'position'))f<-list(list(type='rect'))
    if(length(f)!=1)stop('Unsupported property: ',a$prop)
    f<-f[[1]]; v<-a$value
    if(f$type=='number' && (!is.numeric(v)||length(v)!=1||!is.finite(v)||v<f$min||v>f$max))stop('Invalid number')
    if(f$type=='pair' && (length(unlist(v))!=2||!is.numeric(unlist(v))||any(!is.finite(unlist(v)))))stop('Invalid position')
    if(f$type=='rect' && (length(unlist(v))!=4||!is.numeric(unlist(v))||any(!is.finite(unlist(v)))||any(unlist(v)[3:4]<=0)))stop('Invalid panel rectangle')
    if(f$type=='bool' && (!is.logical(v)||length(v)!=1))stop('Invalid visibility')
    if(a$prop=='size_mm' && any(unlist(v)<=0|unlist(v)>PAGE_SIZE_MAX_MM))stop('Figure size must be positive and no greater than ',PAGE_SIZE_MAX_MM,' mm')
    if(f$type=='text' && (!is.character(v)||length(v)!=1))stop('Invalid text')
    if(f$type=='color')grDevices::col2rgb(v)
    if(f$type=='enum' && !v %in% unlist(f$options))stop('Invalid option')
    if(f$type=='number_list' && (length(unlist(v))>1000||!is.numeric(unlist(v))||any(!is.finite(unlist(v)))))stop('Invalid tick values')
  }
  styles<-Filter(function(a)!a$prop %in% c('pos_frac','visible')||grepl('^(point|errorbar|text)-group-',a$gid),patches)
  if(!building) {
    if(is.null(state$base_result)||!identical(styles,state$styles)) {
      state$base_result<-render(styles,TRUE); state$styles<-styles
    }
    result<-unserialize(serialize(state$base_result,NULL))
    g<-state$base_g
    for(a in patches)if(a$prop=='pos_frac') {
      delta<-unlist(a$value)-state$anchors[[a$gid]]
      g<-move_element(g,a$gid,delta[1]*state$w,delta[2]*state$h)
      for(j in seq_along(result$manifest$elements))if(result$manifest$elements[[j]]$gid==a$gid) {
        e<-result$manifest$elements[[j]];e$bbox[1:2]<-as.list(unlist(e$bbox[1:2])+delta);e$anchor<-as.list(unlist(e$anchor)+delta)
        for(k in seq_along(e$editable))if(e$editable[[k]]$prop=='pos_frac')e$editable[[k]]$value<-e$anchor
        result$manifest$elements[[j]]<-e
      }
      for(j in seq_along(result$fragments))if(result$fragments[[j]]$gid==a$gid) {
        svg<-result$fragments[[j]]$svg
        svg<-sub('(<svg[^>]*>)',paste0('\\1<g transform="translate(',delta[1]*state$w*72/25.4,' ',delta[2]*state$h*72/25.4,')">'),svg)
        result$fragments[[j]]$svg<-sub('</svg>','</g></svg>',svg,fixed=TRUE)
      }
    }
    for(a in patches)if(a$prop=='visible' && identical(a$value,FALSE)&&!grepl('^(point|errorbar|text)-group-',a$gid)) {
      g<-hide_element(g,a$gid)
      for(j in seq_along(result$fragments))if(result$fragments[[j]]$gid==a$gid || identical(result$fragments[[j]]$parent,a$gid))result$fragments[[j]]$svg<-'<svg></svg>'
      for(j in seq_along(result$manifest$elements))if(result$manifest$elements[[j]]$gid==a$gid)for(k in seq_along(result$manifest$elements[[j]]$editable))if(result$manifest$elements[[j]]$editable[[k]]$prop=='visible')result$manifest$elements[[j]]$editable[[k]]$value<-FALSE
    }
    state$g<-g;state$patches<-patches;state$manifest<-result$manifest;state$rev<-state$rev+1L
    result$rev<-state$rev;result$patches<-patches;return(result)
  }
  size<-Filter(function(a)a$gid=='figure'&&a$prop=='size_mm',patches)
  wh<-if(length(size))unlist(size[[length(size)]]$value) else state$page_size_mm
  previous_frame<-state$frame
  w<-wh[1];h<-wh[2];state$w<-w;state$h<-h
  # Older saved projects stored a normalized axes.position alongside the page
  # size. Migrate that one legacy value to the sole physical frame field once
  # per request; new edits and exports use frame_mm only.
  legacy_positions<-Filter(function(a)a$gid=='axes_0'&&a$prop=='position',patches)
  if(length(legacy_positions)) {
    frame_edits<-Filter(function(a)a$gid=='axes_0'&&a$prop=='frame_mm',patches)
    if(!length(frame_edits)) {
      r<-unlist(legacy_positions[[length(legacy_positions)]]$value)
      if(length(r)==4&&all(is.finite(r))) {
        patches<-Filter(function(a)!(a$gid=='axes_0'&&a$prop=='position'),patches)
        patches<-c(patches,list(list(gid='axes_0',prop='frame_mm',value=as.list(c(r[1]*w,(1-r[2]-r[4])*h,r[3]*w,r[4]*h)))))
      }
    } else patches<-Filter(function(a)!(a$gid=='axes_0'&&a$prop=='position'),patches)
  }
  p<-apply_plot(state$p,patches)
  p<-normalize_tavotto_markdown(p,force=TRUE);display_plot_labels<-attr(p,'tavotto_display_labels') %||% p$labels;attr(p,'tavotto_display_labels')<-NULL;p<-render_superscript_minus_labels(p)
  frame_edits<-Filter(function(a)a$gid=='axes_0'&&a$prop=='frame_mm',patches)
  frame<-if(length(frame_edits))unlist(frame_edits[[length(frame_edits)]]$value) else
    state$layout$frame_mm %||% state$source_frame_mm %||% state$default_frame_mm %||% previous_frame
  state$frame<-frame
  set.seed(20260922)
  built<-apply_text_groups(apply_errorbar_groups(apply_point_groups(ggplot_build(p),patches),patches),patches);plot_labels<-built$plot$labels
  for(key in names(display_plot_labels))if(!is.null(display_plot_labels[[key]]))plot_labels[[key]]<-display_plot_labels[[key]]
  # One SVG device establishes identical font metrics for every gtable.
  grDevices::svg(file.path(state$out,'probe.svg'),width=w/25.4,height=h/25.4)
  g<-ggplot_gtable(built); grDevices::dev.off()
  pan<-g$layout[g$layout$name=='panel',]
  if(nrow(pan)!=1)stop('This first R adapter supports one ggplot panel')
  if(is.null(frame)) {
    if(isTRUE(state$cached_render_state))
      stop('This cached single-ggplot object has no source frame metadata. Re-export the cache with its original canvas and frame geometry; refusing to initialize the axes from a full-page standalone render.')
    # For a standalone ggplot, measure the physical panel on its actual source
    # output device. Never shrink or center the panel from the page dimensions.
    cairo_pdf(file.path(state$out,'frame-baseline.pdf'),width=w/25.4,height=h/25.4)
    draw_figure(g,w,h,NULL);grid.force()
    seekViewport(paste0('panel.',pan$t,'-',pan$l,'-',pan$b,'-',pan$r))
    a<-deviceLoc(unit(0,'npc'),unit(0,'npc'),valueOnly=TRUE)
    b<-deviceLoc(unit(1,'npc'),unit(1,'npc'),valueOnly=TRUE)
    frame<-c(a$x*25.4,h-b$y*25.4,(b$x-a$x)*25.4,(b$y-a$y)*25.4)
    dev.off()
    if(length(frame)!=4||any(!is.finite(frame))||any(frame[3:4]<=0))stop('Could not measure the plot frame')
    state$default_frame_mm<-frame;state$frame<-frame
  }
  layout_metrics<-NULL
  if(!is.null(frame)) {
    # Match the source's Cairo PDF layout metrics across preview and all exports.
    cairo_pdf(file.path(state$out,'layout-probe.pdf'),width=w/25.4,height=h/25.4)
    g$widths[pan$l]<-unit(frame[3],'mm');g$heights[pan$t]<-unit(frame[4],'mm')
    layout_metrics<-c(convertWidth(sum(g$widths[seq_len(pan$l-1)]),'mm',TRUE),
      convertHeight(sum(g$heights[seq_len(pan$t-1)]),'mm',TRUE),
      convertWidth(sum(g$widths),'mm',TRUE),convertHeight(sum(g$heights),'mm',TRUE))
    # The page and the axes frame are independent physical rectangles. Preserve
    # all four frame_mm values on page edits, even when that leaves the panel or
    # its labels outside the page; the existing layout warning reports clipping.
    margins<-c(left=layout_metrics[1],top=layout_metrics[2],
      right=layout_metrics[3]-layout_metrics[1]-frame[3],
      bottom=layout_metrics[4]-layout_metrics[2]-frame[4])
    layout_warnings<-character()
    need_w<-frame[3]+max(0,margins[['left']])+max(0,margins[['right']])
    need_h<-frame[4]+max(0,margins[['top']])+max(0,margins[['bottom']])
    if(need_w>w+1e-6 ||
       (frame[1]<margins[['left']]-1e-6 || frame[1]+frame[3]+margins[['right']]>w+1e-6)) {
      layout_warnings<-c(layout_warnings,sprintf(
        'The %.1f mm axes frame and its horizontal labels/gutters do not fit the %.1f mm output page. The axes frame was kept at %.1f mm; enlarge the page or reduce the axes frame to avoid clipping labels.',
        need_w,w,frame[3]))
    }
    if(need_h>h+1e-6 ||
       (frame[2]<margins[['top']]-1e-6 || frame[2]+frame[4]+margins[['bottom']]>h+1e-6)) {
      layout_warnings<-c(layout_warnings,sprintf(
        'The %.1f mm axes frame and its vertical labels/gutters do not fit the %.1f mm output page. The axes frame was kept at %.1f mm; enlarge the page or reduce the axes frame to avoid clipping labels.',
        need_h,h,frame[4]))
    }
    attr(frame,'metrics')<-layout_metrics
    dev.off();state$frame<-frame
  } else layout_warnings<-character()
  if(!is.null(frame)) {
  }
  idx<-which(g$layout$name %in% c('title','subtitle','caption','xlab-b','ylab-l','axis-b','axis-l','guide-box-right','guide-box-left','guide-box-top','guide-box-bottom','guide-box-inside'))
  idx<-idx[!vapply(g$grobs[idx],inherits,logical(1),'zeroGrob')]
  targets<-lapply(idx,function(i)list(gid=g$layout$name[[i]],i=i))
  pi<-which(g$layout$name=='panel')
  if(length(pi)!=1)stop('This first R adapter supports one ggplot panel')
  children<-g$grobs[[pi]]$children
  if(length(children)==length(p$layers)+4L && startsWith(names(children)[[1]],'grill.'))
    for(j in seq_along(p$layers))targets[[length(targets)+1L]]<-list(gid=paste0('layer-',j),i=pi,child=j+2L,layer=j)
  targets<-targets[order(vapply(targets,function(d)g$layout$z[[d$i]]+(d$child %||% 0)/1000,numeric(1)))]
  for(a in patches)if(a$prop=='pos_frac') {
    d<-Filter(function(d)d$gid==a$gid,targets)[[1]]; origin<-state$anchors[[a$gid]]
    g<-move_grob(g,d$i,(unlist(a$value)[1]-origin[1])*w,(unlist(a$value)[2]-origin[2])*h)
  }
  background<-g
  for(d in targets)if(is.null(d$child))background$grobs[[d$i]]<-nullGrob() else background$grobs[[d$i]]$children[[d$child]]<-nullGrob()
  fragments<-list(); elements<-list();warnings<-as.list(layout_warnings)
  cache_hits<-0L;cache_misses<-0L
  # The preview can display a frame outside the output page. Its larger device
  # is an internal drawing envelope, never a third editable size. Export devices
  # retain the source page dimensions and naturally crop to that paper.
  preview_left<-if(is.null(frame))0 else max(0,35-frame[[1L]])
  preview_top<-if(is.null(frame))0 else max(0,35-frame[[2L]])
  preview_w<-if(is.null(frame))w else max(w,frame[[1L]]+frame[[3L]]+35)+preview_left
  preview_h<-if(is.null(frame))h else max(h,frame[[2L]]+frame[[4L]]+35)+preview_top
  if(any(!is.finite(c(preview_w,preview_h)))||any(c(preview_w,preview_h)>5000))
    stop('The plot frame is too far from the output page to preview safely. Reduce its position or size.')
  preview_frame<-frame
  if(!is.null(preview_frame))preview_frame[1:2]<-preview_frame[1:2]+c(preview_left,preview_top)
  draw_svg<-function(obj,file) {
    grDevices::svg(file,width=preview_w/25.4,height=preview_h/25.4,bg='transparent')
    draw_figure(obj,preview_w,preview_h,preview_frame);grDevices::dev.off()
    svg<-paste(readLines(file,warn=FALSE),collapse='\n')
    if(preview_left!=0||preview_top!=0) {
      svg<-sub('(<svg[^>]*>)',paste0('\\1<g transform="translate(',
        -preview_left*72/25.4,' ',-preview_top*72/25.4,')">'),svg)
      svg<-sub('</svg>','</g></svg>',svg,fixed=TRUE)
    }
    svg
  }
  draw_piece<-function(obj,gid,bbox_hint=NULL) {
    key<-digest::digest(list(stable_grob(obj),w,h,frame),algo='xxhash64')
    cached<-state$pieces[[gid]]
    if(!is.null(cached)&&identical(cached$key,key)){cache_hits<<-cache_hits+1L;return(cached)}
    cache_misses<<-cache_misses+1L
    svg<-draw_svg(obj,file.path(state$out,paste0('piece-',gid,'.svg')))
    if(!is.null(bbox_hint))bbox<-bbox_hint else {
      raster<-file.path(state$out,'hit-test.png')
      probe_dpi<-min(144,1800*25.4/max(preview_w,preview_h))
      png(raster,width=max(1,round(preview_w/25.4*probe_dpi)),height=max(1,round(preview_h/25.4*probe_dpi)),res=probe_dpi,type='cairo',bg='transparent')
      draw_figure(obj,preview_w,preview_h,preview_frame);dev.off()
      pix<-png::readPNG(raster);ink<-which(pix[,,4]>.05,arr.ind=TRUE)
      bbox<-if(nrow(ink))c(((min(ink[,2])-1)/dim(pix)[2]*preview_w-preview_left)/w,
        ((min(ink[,1])-1)/dim(pix)[1]*preview_h-preview_top)/h,
        (max(ink[,2])-min(ink[,2])+1)/dim(pix)[2]*preview_w/w,
        (max(ink[,1])-min(ink[,1])+1)/dim(pix)[1]*preview_h/h) else NULL
    }
    result<-list(key=key,svg=svg,bbox=bbox %||% cached$bbox)
    state$pieces[[gid]]<-result;result
  }
  background_key<-digest::digest(list(stable_grob(background),w,h,frame),algo='xxhash64')
  if(!identical(background_key,state$background_key)) {
    state$background_svg<-draw_svg(background,file.path(state$out,'background.svg'));state$background_key<-background_key
  }
  fragments[[1]]<-list(gid='background',svg=state$background_svg)
  panel_fraction<-if(!is.null(frame))c(frame[1]/w,frame[2]/h,frame[3]/w,frame[4]/h) else NULL
  point_group_geometry<-function(data,rows) {
    if(is.null(panel_fraction)||!length(rows))return(NULL)
    transformed<-tryCatch(p$coordinates$transform(data[rows,,drop=FALSE],built$layout$panel_params[[1]]),error=function(e)NULL)
    if(is.null(transformed)||!all(c('x','y')%in%names(transformed)))return(NULL)
    sizes<-if('size'%in%names(data))as.numeric(data$size[rows]) else rep(1.5,length(rows))
    strokes<-if('stroke'%in%names(data))as.numeric(data$stroke[rows]) else rep(.5,length(rows))
    n<-min(length(rows),nrow(transformed),length(sizes),length(strokes))
    keep<-which(is.finite(transformed$x[seq_len(n)])&is.finite(transformed$y[seq_len(n)]))
    if(!length(keep))return(NULL)
    paths<-lapply(keep,function(j) {
      # ggplot2 point size and stroke are millimetres; an 12-sided outline keeps
      # canvas hit testing on the dots instead of their group's empty bounding box.
      rx<-(sizes[j]+strokes[j])/2/w;ry<-(sizes[j]+strokes[j])/2/h
      theta<-seq(0,2*pi,length.out=13L)
      list(points=lapply(theta,function(a)as.list(c(panel_fraction[1]+transformed$x[j]*panel_fraction[3]+cos(a)*rx,
        panel_fraction[2]+(1-transformed$y[j])*panel_fraction[4]+sin(a)*ry))),closed=TRUE)
    })
    list(kind='multi_path',paths=paths,fill=TRUE,stroke=TRUE,
      stroke_pt=max(strokes[keep],na.rm=TRUE)*72.27/25.4,clip=as.list(panel_fraction))
  }
  rect_group_geometry<-function(data,rows) {
    if(is.null(panel_fraction)||!length(rows)||!all(c('xmin','xmax','ymin','ymax')%in%names(data)))return(NULL)
    corners<-do.call(rbind,lapply(rows,function(i)data.frame(
      x=c(data$xmin[i],data$xmax[i],data$xmax[i],data$xmin[i]),
      y=c(data$ymin[i],data$ymin[i],data$ymax[i],data$ymax[i]))))
    transformed<-tryCatch(p$coordinates$transform(corners,built$layout$panel_params[[1]]),error=function(e)NULL)
    if(is.null(transformed)||!all(c('x','y')%in%names(transformed)))return(NULL)
    linewidth<-if('linewidth'%in%names(data))max(as.numeric(data$linewidth[rows]),na.rm=TRUE) else .5
    paths<-lapply(seq_along(rows),function(i) {
      ix<-((i-1L)*4L+1L):(i*4L)
      if(any(!is.finite(transformed$x[ix]))||any(!is.finite(transformed$y[ix])))return(NULL)
      list(points=lapply(ix,function(j)as.list(c(panel_fraction[1]+transformed$x[j]*panel_fraction[3],
        panel_fraction[2]+(1-transformed$y[j])*panel_fraction[4]))),closed=TRUE)
    })
    paths<-Filter(Negate(is.null),paths);if(!length(paths))return(NULL)
    list(kind='multi_path',paths=paths,fill=TRUE,stroke=TRUE,
      stroke_pt=linewidth*72.27/25.4,clip=as.list(panel_fraction))
  }
  errorbar_group_geometry<-function(grob,series) {
    if(is.null(panel_fraction)||length(grob$id)!=length(grob$x)||length(grob$x)!=length(grob$y))return(NULL)
    ix<-which(grob$id==series);if(!length(ix))return(NULL)
    x<-as.numeric(grob$x[ix]);y<-as.numeric(grob$y[ix]);finite<-is.finite(x)&is.finite(y)
    at<-which(finite);if(!length(at))return(NULL)
    run_id<-cumsum(c(TRUE,diff(at)>1L));runs<-split(at,run_id)
    paths<-unname(lapply(runs,function(run) {
      list(points=lapply(run,function(j)as.list(c(
        panel_fraction[1]+x[j]*panel_fraction[3],panel_fraction[2]+(1-y[j])*panel_fraction[4]))),closed=FALSE)
    }))
    linewidth<-if(length(grob$gp$lwd)>=series)as.numeric(grob$gp$lwd[series]) else .5
    list(kind='multi_path',paths=paths,fill=FALSE,stroke=TRUE,
      stroke_pt=linewidth,clip=as.list(panel_fraction))
  }
  geometry_bbox<-function(geometry) {
    if(is.null(geometry)||!length(geometry$paths))return(NULL)
    point_matrices<-lapply(geometry$paths,function(path) {
      if(!length(path$points))return(NULL)
      do.call(rbind,lapply(path$points,function(point)as.numeric(unlist(point))))
    })
    points<-do.call(rbind,Filter(Negate(is.null),point_matrices))
    if(is.null(points)||!nrow(points))return(NULL)
    c(min(points[,1]),min(points[,2]),diff(range(points[,1])),diff(range(points[,2])))
  }
  # Unsplit line/reference-line layers are visible artists too. Use their
  # actual grid paths rather than the empty area inside their bounding box.
  layer_grob_geometry<-function(grob) {
    if(is.null(panel_fraction))return(NULL)
    paths<-list()
    add_path<-function(x,y,closed=FALSE) {
      finite<-which(is.finite(x)&is.finite(y));if(!length(finite))return()
      runs<-split(finite,cumsum(c(TRUE,diff(finite)>1L)))
      for(run in runs)if(length(run)>=2L)paths[[length(paths)+1L]]<<-list(
        points=lapply(run,function(j)as.list(c(panel_fraction[1]+x[j]*panel_fraction[3],
          panel_fraction[2]+(1-y[j])*panel_fraction[4]))),closed=closed)
    }
    if(inherits(grob,'segments')) {
      x0<-as.numeric(grob$x0);y0<-as.numeric(grob$y0);x1<-as.numeric(grob$x1);y1<-as.numeric(grob$y1)
      count<-max(length(x0),length(y0),length(x1),length(y1))
      if(!count||any(c(length(x0),length(y0),length(x1),length(y1))==0L))return(NULL)
      x0<-rep_len(x0,count);y0<-rep_len(y0,count);x1<-rep_len(x1,count);y1<-rep_len(y1,count)
      for(j in seq_len(count))add_path(c(x0[j],x1[j]),c(y0[j],y1[j]))
    } else if(inherits(grob,c('polyline','polygon'))) {
      x<-as.numeric(grob$x);y<-as.numeric(grob$y);if(length(x)!=length(y)||!length(x))return(NULL)
      ids<-grob$id
      if(is.null(ids)&&!is.null(grob$id.lengths))ids<-rep(seq_along(grob$id.lengths),grob$id.lengths)
      if(is.null(ids))ids<-rep(1L,length(x))
      if(length(ids)!=length(x))return(NULL)
      for(id in unique(ids)) {ix<-which(ids==id);add_path(x[ix],y[ix],inherits(grob,'polygon'))}
    } else return(NULL)
    if(!length(paths))return(NULL)
    list(kind='multi_path',paths=paths,fill=inherits(grob,'polygon'),stroke=TRUE,
      stroke_pt=if(length(grob$gp$lwd))max(as.numeric(grob$gp$lwd),na.rm=TRUE) else .5,
      clip=as.list(panel_fraction))
  }
  group_label<-function(current,fallback) {
    pp<-built$layout$panel_params[[1]]$x
    if(!is.null(pp)&&pp$is_discrete()&&'x'%in%names(current)) {
      positions<-suppressWarnings(as.numeric(current$x));positions<-positions[is.finite(positions)]
      labels<-as.character(pp$get_labels())
      ix<-if(length(positions))as.integer(round(stats::median(positions))) else NA_integer_
      if(!is.na(ix)&&ix>=1&&ix<=length(labels))return(labels[[ix]])
    }
    for(aesthetic in c('fill','colour')) {
      sc<-built$plot$scales$get_scales(aesthetic)
      if(!is.null(sc)&&sc$is_discrete()&&aesthetic%in%names(current)) {
        mapped<-unique(current[[aesthetic]]);levels<-sc$get_limits();ix<-match(mapped,sc$map(levels))
        if(length(ix)==1&&!is.na(ix))return(as.character(levels[ix]))
      }
    }
    if(!is.null(pp)&&pp$is_discrete()&&'x'%in%names(current)) {
      labels<-as.character(pp$get_labels());ix<-as.integer(as.numeric(current$x[[1]]))
      if(is.finite(ix)&&ix>=1&&ix<=length(labels))return(labels[[ix]])
    }
    fallback
  }
  figure_component_fields<-function() {
    out<-list()
    add_component<-function(prop,type,value,group,expression=NULL) {
      field<-list(prop=prop,type=type,value=value,group=group,primary=FALSE)
      if(type=='number')field<-c(field,list(min=-1e9,max=1e9,step=.1))
      if(!is.null(expression))field$r_expression<-expression
      out[[length(out)+1L]]<<-field
    }
    component_field<-function(prop,value,group,expression=NULL) {
      expression_prop<-if(startsWith(prop,'r_expr::'))prop else paste0('r_expr::',prop)
      expression_overrides<-Filter(function(a)identical(a$prop,expression_prop),patches)
      expression_override<-length(expression_overrides)>0L
      if(expression_override) {
        edited_value<-expression_overrides[[length(expression_overrides)]]$value
        expr<-if(is.character(edited_value)&&length(edited_value)==1L)edited_value else literal(value)
        if(nchar(expr)>10000L)return()
        add_component(expression_prop,'text',expr,group,expression %||% paste0(prop,' <- ',expr));return()
      }
      simple<-is.atomic(value)&&length(value)==1L&&!is.na(value)&&!is.function(value)
      if(!simple) {
        expr<-literal(value);if(nchar(expr)>10000L)return()
        add_component(paste0('r_expr::',prop),'text',expr,group,expression %||% paste0(prop,' <- ',expr));return()
      }
      is_color<-is.character(value)&&grepl('color|colour|fill|na[.]value',prop,ignore.case=TRUE)&&!inherits(try(grDevices::col2rgb(value),silent=TRUE),'try-error')
      type<-if(is.logical(value))'bool' else if(is.numeric(value))'number' else if(is_color)'color' else 'text'
      add_component(prop,type,value,group,expression)
    }
    mapping_text<-function(x) {
      expr<-if(rlang::is_quosure(x))rlang::quo_get_expr(x) else x
      paste(deparse(expr,width.cutoff=500L),collapse='')
    }
    constructor_function<-function(object,prefix) {
      call<-tryCatch(object$call,error=function(e)NULL)
      called<-tryCatch(as.character(call[[1]])[[1]],error=function(e)'')
      fallback<-paste0(prefix,tolower(sub('^(Scale|Coord|Facet|Guide)','',class(object)[[1]])))
      name<-if(nzchar(called))called else fallback
      fn<-tryCatch(get(name,mode='function',envir=state$env,inherits=TRUE),error=function(e)NULL)
      if(!is.function(fn))fn<-tryCatch(get(name,mode='function',envir=asNamespace('ggplot2'),inherits=FALSE),error=function(e)NULL)
      fn
    }
    constructor_parameters<-function(object,prefix) {
      fn<-constructor_function(object,prefix)
      if(is.function(fn))return(setdiff(names(formals(fn)),'...'))
      call<-tryCatch(object$call,error=function(e)NULL)
      called_args<-tryCatch(setdiff(names(as.list(call)),''),error=function(e)character())
      setdiff(called_args,'...')
    }
    constructor_defaults<-function(object,prefix) {
      fn<-constructor_function(object,prefix)
      if(!is.function(fn))return(list())
      fml<-formals(fn);out<-list()
      for(n in setdiff(names(fml),'...')) {
        expr<-fml[[n]]
        if(identical(expr,quote(expr=)))next
        value<-tryCatch(eval(expr,envir=environment(fn)),error=function(e)NULL)
        out[n]<-list(value)
      }
      out
    }
    constructor_call_arguments<-function(object) {
      call<-tryCatch(object$call,error=function(e)NULL)
      if(!is.call(call)||length(call)<2L)return(list())
      as.list(call)[-1L]
    }
    constructor_default_expressions<-function(object,prefix) {
      fn<-constructor_function(object,prefix)
      if(!is.function(fn))return(list())
      fml<-formals(fn);out<-list()
      for(n in setdiff(names(fml),'...')) {
        missing_formal<-formals(function(placeholder)NULL)[1L];names(missing_formal)<-n
        if(identical(fml[n],missing_formal))next
        out[n]<-list(fml[[n]])
      }
      out
    }
    constructor_call_name<-function(object,prefix) {
      call<-tryCatch(object$call,error=function(e)NULL)
      name<-if(is.call(call))paste(deparse(call[[1L]],width.cutoff=500L),collapse='')else''
      if(nzchar(name))name else paste0(prefix,tolower(sub('^(Scale|Coord|Facet|Guide)','',class(object)[[1]])))
    }
    expression_text<-function(expr)paste(deparse(expr,width.cutoff=500L),collapse='')
    for(n in names(p$mapping)) {
      text<-mapping_text(p$mapping[[n]])
      component_field(paste0('mapping::plot::',n),text,'r_mapping_params',paste0('aes(',n,' = ',text,')'))
    }
    if(length(p$guides$guides))for(aesthetic in names(p$guides$guides)) {
      guide<-p$guides$guides[[aesthetic]]
      guide_name<-switch(class(guide)[[1]],GuideLegend='guide_legend',GuideColourbar='guide_colourbar',GuideColorbar='guide_colorbar',GuideNone='guide_none',
        paste0('guide_',tolower(sub('^Guide','',class(guide)[[1]]))))
      guide_args<-constructor_parameters(guide,'guide_')
      guide_defaults<-constructor_defaults(guide,'guide_')
      guide_params<-tryCatch(guide$params,error=function(e)NULL)
      if(!is.list(guide_params))guide_params<-list()
      if(length(guide_args))guide_params<-guide_params[intersect(names(guide_params),guide_args)] else guide_params<-guide_params[setdiff(names(guide_params),c('name','hash'))]
      guide_values<-utils::modifyList(guide_defaults,guide_params,keep.null=TRUE)
      for(n in names(guide_values)) {
        value<-guide_values[[n]];if(is.environment(value))next
        component_field(paste0('guides::',aesthetic,'::',n),value,paste0('图例 ',aesthetic),
          paste0(guide_name,'(',n,' = VALUE)'))
      }
    }
    scale_parameter_names<-function(scale) {
      args<-constructor_parameters(scale,'scale_')
      if(length(args)) {
        # ggplot2 4.x retains the former `trans` argument as a deprecated
        # sentinel beside the public `transform` argument. It is not a second
        # drawable property and evaluating its default raises a missing-arg
        # error, so expose only the current constructor parameter.
        if('transform'%in%args)args<-setdiff(args,'trans')
        return(args)
      }
      unique(setdiff(names(scale),c('super','range','aesthetics','call','env','trans','palette','breaks','minor_breaks','labels','limits','expand','oob','na.value','guide','position','sec.axis','name')))
    }
    if(length(p$scales$scales))for(i in seq_along(p$scales$scales)) {
      scale<-p$scales$scales[[i]];scale_aesthetic<-if(length(scale$aesthetics))scale$aesthetics[[1L]]else'unknown'
      scale_group<-paste0('标度 ',i,' · ',scale_aesthetic)
      scale_call<-constructor_call_name(scale,'scale_')
      scale_call_args<-constructor_call_arguments(scale)
      scale_default_exprs<-constructor_default_expressions(scale,'scale_')
      for(n in setdiff(scale_parameter_names(scale),c('super','range','aesthetics','call'))) {
        # Scale ggproto inherits callable methods named `breaks`, `labels`,
        # `oob` and `transform`. Prefer the retained constructor call/default,
        # rather than exposing those internal methods as if they were values.
        # ggplot2's public `transform` argument is stored in the `trans` slot.
        stored_name<-if(n=='transform')'trans'else n
        value<-tryCatch(scale[[stored_name]],error=function(e)NULL)
        explicitly_set<-n%in%names(scale_call_args)
        source_expr<-if(explicitly_set)scale_call_args[[n]]else scale_default_exprs[[n]]
        function_parameter<-FALSE
        expression_argument<-FALSE
        if(!is.null(source_expr)) {
          # Do not evaluate a retained script expression a second time just to
          # inspect its type: it may call user code. Scalar literals get native
          # controls; calls, vectors and functions stay lossless R expressions.
          simple_source<-is.atomic(source_expr)&&length(source_expr)==1L&&!is.na(source_expr)&&!is.function(source_expr)
          expression_argument<-!simple_source||n=='transform'
          if(simple_source&&n!='transform')value<-source_expr else value<-expression_text(source_expr)
          if(explicitly_set&&n%in%c('breaks','labels')) {
            function_parameter<-is.symbol(source_expr)||
              (is.call(source_expr)&&identical(source_expr[[1L]],as.name('function')))
          }
        }
        if(is.environment(value))next
        axis_scale<-any(scale$aesthetics%in%c('x','y'))
        # These x/y properties already have one direct owner in the axis
        # inspector: name -> axis title, static breaks/labels -> tick controls,
        # static breaks/labels -> tick controls. Keep that one-to-one ownership;
        # function-valued tick rules and scale transformations remain here as
        # explicit constructor parameters.
        if(axis_scale&&n=='name')next
        if(axis_scale&&n%in%c('breaks','labels')&&!function_parameter)next
        if(expression_argument) {
          component_field(paste0('r_expr::scale::',i,'::',n),value,scale_group,
            paste0(scale_call,'(',n,' = VALUE)'))
          next
        }
        component_field(paste0('scale::',i,'::',n),value,scale_group,paste0(scale_call,'(',n,' = VALUE)'))
      }
    }
    coord_cartesian<-identical(class(p$coordinates)[1],'CoordCartesian')
    coord_params<-constructor_parameters(p$coordinates,'coord_')
    if(!length(coord_params))coord_params<-setdiff(names(p$coordinates),c('super','default','call','limits','range','scale_is_discrete'))
    coord_call<-constructor_call_name(p$coordinates,'coord_')
    for(n in coord_params) {
      if(coord_cartesian&&n=='limits')next
      if(coord_cartesian&&n%in%c('xlim','ylim'))next # axis inspector owns coord_cartesian limits
      value<-if(coord_cartesian&&n%in%c('xlim','ylim'))p$coordinates$limits[[if(n=='xlim')'x'else'y']] else p$coordinates[[n]]
      if(is.environment(value))next
      component_field(paste0('coord::',n),value,'r_coord_params',paste0(coord_call,'(',n,' = VALUE)'))
    }
    if(!inherits(p$facet,'FacetNull')) {
      facet_params<-constructor_parameters(p$facet,'facet_')
      if(!length(facet_params))facet_params<-names(p$facet$params)
      facet_call<-constructor_call_name(p$facet,'facet_')
      for(n in facet_params)component_field(paste0('facet::',n),p$facet$params[[n]],'r_facet_params',paste0(facet_call,'(',n,' = VALUE)'))
    }
    theme_base<-theme_get()+p$theme
    role_theme_props<-c(
      paste0(rep(c('plot.title','plot.subtitle','plot.caption','axis.title.x','axis.title.y'),each=5),'::',rep(c('size','family','colour','face','angle'),times=5)),
      paste0(rep(c('axis.text.x','axis.text.y'),each=4),'::',rep(c('size','family','colour','angle'),times=2)),
      'axis.ticks.length.x::value','axis.ticks.length.y::value','axis.ticks.x::linewidth','axis.ticks.y::linewidth',
      'legend.position::value','legend.text::size','legend.text::family','legend.text::colour',
      'legend.title::size','legend.title::family','legend.title::colour','legend.background::fill','legend.background::colour','legend.background::linewidth',
      'panel.background::fill','panel.border::colour','panel.border::linewidth','panel.grid.major::colour','panel.grid.major::linewidth','panel.grid.major::linetype')
    # Theme components are editable even when inherited from the active base
    # theme. Enumerate the resolved ggplot theme, not only names explicitly
    # authored in p$theme; otherwise ordinary drawable defaults (panel grids,
    # strip text, legend keys, margins, etc.) have no interaction at all.
    for(n in unique(c(names(theme_get()),names(p$theme)))) {
      if(n%in%c('legend.position','axis.ticks.length.x','axis.ticks.length.y'))next
      element<-tryCatch(ggplot2::calc_element(n,theme_base),error=function(e)NULL);if(is.null(element))next
      base_element<-tryCatch(ggplot2::calc_element(n,theme_get()),error=function(e)NULL)
      if(inherits(element,'element_blank')) {
        add_component(paste0('r_expr::theme::',n,'::element'),'text','element_blank()',paste0('r_theme_element::',n),paste0('theme(',n,' = element_blank())'))
      } else if(!inherits(element,c('element_text','element_line','element_rect'))) {
        expr<-literal(element);if(nchar(expr)<=10000L)add_component(paste0('r_expr::theme::',n,'::element'),'text',expr,paste0('r_theme_element::',n),paste0('theme(',n,' = ',expr,')'))
      } else {
        element_values<-if(inherits(element,c('element_text','element_line','element_rect')))tryCatch(S7::props(element),error=function(e)element) else if(is.list(element))element else NULL
        if(!is.null(element_values))for(k in names(element_values)) {
        value<-element_values[[k]];if(is.environment(value)||paste(n,k,sep='::')%in%role_theme_props)next
        prop<-paste0('theme::',n,'::',k)
        group<-paste0('r_theme_element::',n)
        if(is.null(value)) {
          expr<-literal(value);type<-class(element)[1]
          add_component(paste0('r_expr::',prop),'text',expr,group,paste0('theme(',n,' = ',type,'(',k,' = ',expr,'))'))
        } else component_field(prop,value,group,paste0('theme(',n,' = ',class(element)[1],'(',k,' = VALUE))'))
      }
      }
    }
    out
  }
  for(k in seq_along(targets)) {
    d<-targets[[k]]; one<-g
    for(j in setdiff(seq_along(g$grobs),d$i))one$grobs[[j]]<-nullGrob()
    if(!is.null(d$child))for(j in setdiff(seq_along(one$grobs[[d$i]]$children),d$child))one$grobs[[d$i]]$children[[j]]<-nullGrob()
    split_points<-!is.null(d$layer)&&inherits(p$layers[[d$layer]]$geom,'GeomPoint')&&
      inherits(one$grobs[[d$i]]$children[[d$child]],'points')&&length(unique(built$data[[d$layer]]$group))>1&&
      all(built$data[[d$layer]]$group>0)&&length(one$grobs[[d$i]]$children[[d$child]]$x)==nrow(built$data[[d$layer]])
    split_errorbars<-!is.null(d$layer)&&inherits(p$layers[[d$layer]]$geom,'GeomErrorbar')&&
      inherits(one$grobs[[d$i]]$children[[d$child]],'polyline')&&length(unique(built$data[[d$layer]]$group))>1&&
      length(one$grobs[[d$i]]$children[[d$child]]$id)==length(one$grobs[[d$i]]$children[[d$child]]$x)&&
      setequal(unique(one$grobs[[d$i]]$children[[d$child]]$id),seq_along(unique(built$data[[d$layer]]$group)))
    split_text<-!is.null(d$layer)&&inherits(p$layers[[d$layer]]$geom,'GeomText')&&
      inherits(one$grobs[[d$i]]$children[[d$child]],'text')&&
      length(one$grobs[[d$i]]$children[[d$child]]$label)==nrow(built$data[[d$layer]])&&nrow(built$data[[d$layer]])>0
    split_layer<-split_points||split_errorbars||split_text
    piece<-if(split_layer)list(svg='<svg/>',bbox=c(0,0,1,1)) else draw_piece(one,d$gid)
    fragments[[length(fragments)+1L]]<-list(gid=d$gid,svg=piece$svg)
    bx<-piece$bbox
    if(is.null(bx)) {
      if(startsWith(d$gid,'guide-box'))warnings<-c(warnings,list('The legend lies outside the fixed canvas. Enlarge the canvas or choose an inside legend position.'))
      next
    }
    anchor<-bx[1:2]+bx[3:4]/2
    state$anchors[[d$gid]]<-anchor
    fields<-list(); add<-function(prop,type,value,...) {
      extra<-list(...)
      # Keep common role controls in Tavotto's primary form. R-native drawing
      # parameters remain individual fields on their owning layer/component.
      if(!grepl('^(geom::|aes::|position::|theme::)',prop))extra$primary<-TRUE
      fields[[length(fields)+1L]]<<-c(list(prop=prop,type=type,value=value),extra)
    }
    ticks<-startsWith(d$gid,'axis-')
    movable<-(is.null(d$layer)&&!ticks)||(!is.null(d$layer)&&inherits(p$layers[[d$layer]]$geom,'GeomText')); role<-if(ticks)'ticks' else if(!movable)'line' else if(startsWith(d$gid,'guide-box'))'legend' else 'text'
    add('visible','bool',TRUE)
    if(movable)add('pos_frac','pair',as.list(anchor))
    labsmap<-c(title='title',subtitle='subtitle',caption='caption','xlab-b'='x','ylab-l'='y')
    if(d$gid %in% names(labsmap)) {
      if(d$gid%in%c('xlab-b','ylab-l'))role<-'axis_label'
      key<-labsmap[[d$gid]]; label<-as.character(plot_labels[[key]] %||% '')
      tm<-c(title='plot.title',subtitle='plot.subtitle',caption='plot.caption','xlab-b'='axis.title.x','ylab-l'='axis.title.y')[[d$gid]]
      et<-ggplot2::calc_element(tm,ggplot2::theme_get()+p$theme)
      add('fontfamily','enum',et$family %||% '',options=as.list(unique(c(et$family %||% '', 'sans','serif','mono','Arial','Times New Roman'))));
      add('text','text',label,mathtext=FALSE);add('fontsize','number',et$size %||% 11,min=4,max=72,step=.5)
      add('color','color',et$colour %||% 'black');add('fontweight','enum',if(identical(et$face,'bold'))'bold' else 'normal',options=list('normal','bold'))
      add('rotation','number',et$angle %||% 0,min=-180,max=180,step=1)
    } else if(ticks) {
      tm<-if(d$gid=='axis-b')'axis.text.x' else 'axis.text.y';et<-ggplot2::calc_element(tm,ggplot2::theme_get()+p$theme)
      label<-if(d$gid=='axis-b')'X-axis ticks' else 'Y-axis ticks'
      add('fontfamily','enum',et$family %||% '',options=as.list(unique(c(et$family %||% '', 'sans','serif','mono','Arial','Times New Roman'))));
      add('fontsize','number',et$size %||% 11,min=4,max=72,step=.5);add('color','color',et$colour %||% 'black');add('rotation','number',et$angle %||% 0,min=-180,max=180,step=5)
      ax<-if(d$gid=='axis-b')'x' else 'y';pp<-built$layout$panel_params[[1]][[ax]]
      if(identical(class(p$coordinates)[1],'CoordCartesian')&&!pp$is_discrete())add(paste0(ax,'lim'),'pair',as.list(axis_limits(p,built,ax)),unit='data units')
      if(!pp$is_discrete()) {
        br<-pp$breaks[is.finite(pp$breaks)]
        sc<-built$plot$scales$get_scales(ax);if(!is.null(sc$trans))br<-sc$trans$inverse(br)
        mode<-Filter(function(a)a$gid==d$gid&&a$prop=='major_mode',patches)
        add('major_mode','enum',if(length(mode))mode[[length(mode)]]$value else 'auto',options=list('auto','step','fixed'))
        add('major_step','number',if(length(br)>1)as.numeric(diff(br)[1]) else 0,min=0,max=1e9,step=.5)
        add('major_values','number_list',as.list(br))
        add('format','enum','auto',options=list('auto','integer','decimal','scientific','percent'))
      }
      tick_labels<-as.character(pp$get_labels())
      if(is.numeric(pp$breaks)) {
        valid_ticks<-is.finite(pp$breaks)
        if(length(tick_labels)==length(valid_ticks))tick_labels<-tick_labels[valid_ticks]
      }
      tick_labels<-tick_labels[!is.na(tick_labels)]
      add('tick_labels','text',paste(tick_labels,collapse='\n'))
      tickline<-ggplot2::calc_element(paste0('axis.ticks.',ax),theme_get()+p$theme)
      ticklength<-ggplot2::calc_element(paste0('axis.ticks.length.',ax),theme_get()+p$theme)
      add('width','number',tickline$linewidth %||% .5,min=0,max=5,step=.1,unit='mm')
      add('length','number',if(is.null(ticklength))2.75 else abs(convertUnit(ticklength,'pt',valueOnly=TRUE)),min=0,max=30,step=.5,unit='pt')
      add('direction','enum',if(!is.null(ticklength)&&convertUnit(ticklength,'pt',valueOnly=TRUE)<0)'in' else 'out',options=list('in','out'))
    } else label<-if(is.null(d$layer))'Legend' else paste('Layer',d$layer,class(p$layers[[d$layer]]$geom)[1])
    if(startsWith(d$gid,'guide-box')) {
      et<-ggplot2::calc_element('legend.text',ggplot2::theme_get()+p$theme)
      add('fontsize','number',et$size %||% 11,min=4,max=72,step=.5)
      add('fontfamily','enum',et$family %||% '',options=as.list(unique(c(et$family %||% '', 'sans','serif','mono','Arial','Times New Roman'))))
      add('color','color',et$colour %||% 'black')
      add('title','text',as.character(plot_labels$fill %||% plot_labels$colour %||% ''))
      add('ncol','number',1,min=1,max=10,step=1)
      title_theme<-ggplot2::calc_element('legend.title',theme_get()+p$theme)
      bg<-ggplot2::calc_element('legend.background',theme_get()+p$theme)
      add('title_fontsize','number',title_theme$size %||% 11,min=4,max=72,step=.5)
      add('frameon','bool',!inherits(bg,'element_blank'))
      add('edgecolor','color',if(is.null(bg$colour)||is.na(bg$colour))'transparent' else bg$colour)
      add('facecolor','color',if(is.null(bg$fill)||is.na(bg$fill))'transparent' else bg$fill)
      add('frame_linewidth','number',bg$linewidth %||% .5,min=0,max=5,step=.1,unit='mm')
      for(prop in c('labelspacing','handlelength','handleheight')) {
        n<-switch(prop,labelspacing='legend.key.spacing.y',handlelength='legend.key.width',handleheight='legend.key.height')
        u<-ggplot2::calc_element(n,theme_get()+p$theme)
        val<-tryCatch(convertUnit(u,'mm',valueOnly=TRUE),error=function(e)5)
        add(prop,'number',val,min=0,max=50,step=.5,unit='mm')
      }
    }
    if(!is.null(d$layer)) {
      fixed<-p$layers[[d$layer]]$aes_params
      values<-built$data[[d$layer]]
      first_value<-function(key,fallback){v<-unique(values[[key]]);if(length(v)==1&&!is.na(v))v else fallback}
      add('color','color',fixed$colour %||% first_value('colour','#333333'));add('alpha','number',fixed$alpha %||% 1,min=0,max=1,step=.05)
      if(inherits(p$layers[[d$layer]]$geom,'GeomPoint')) {
        role<-'scatter';add('markersize','number',fixed$size %||% first_value('size',1.5),min=.1,max=15,step=.1,unit='mm')
        sh<-first_value('shape',19);fill_value<-fixed$fill %||% first_value('fill',fixed$colour %||% first_value('colour','#333333'))
        if(as.numeric(sh)%in%21:25)add('facecolor','color',fill_value)
        marker<-names(point_shapes)[match(sh,point_shapes)]
        add('marker','enum',if(is.na(marker))'o' else marker,options=as.list(names(point_shapes)))
        add('markeredgewidth','number',fixed$stroke %||% first_value('stroke',.5),min=0,max=5,step=.1)
      }
      else if(inherits(p$layers[[d$layer]]$geom,'GeomText')) {
        role<-'text';texts<-unique(as.character(values$label))
        if(length(texts)==1)add('text','text',texts[[1]],mathtext=FALSE)
        add('fontsize','number',(fixed$size %||% first_value('size',3.88))*(72.27/25.4),min=4,max=72,step=.5)
        add('rotation','number',fixed$angle %||% 0,min=-180,max=180,step=5)
        add('fontfamily','enum',first_value('family',''),options=as.list(unique(c(first_value('family',''),'sans','serif','mono','Arial','Times New Roman'))))
        add('fontweight','enum',if(identical(first_value('fontface',1),2))'bold' else 'plain',options=list('plain','bold','italic','bold.italic'))
        add('hjust','number',first_value('hjust',.5),min=-2,max=3,step=.1)
        add('vjust','number',first_value('vjust',.5),min=-2,max=3,step=.1)
      } else {
        add('linewidth','number',fixed$linewidth %||% .5,min=.1,max=10,step=.1)
        if(inherits(p$layers[[d$layer]]$geom,'GeomBar')) {
          role<-'bar_series';add('facecolor','color',fixed$fill %||% first_value('fill','#999999'))
          # Width is a data-space property, not stroke width or canvas scale.
          if(any(vapply(c('PositionIdentity','PositionStack'),function(cls)inherits(p$layers[[d$layer]]$position,cls),logical(1))) &&
             !isTRUE(values$flipped_aes[1])) {
            widths<-unique(values$xmax-values$xmin)
            if(length(widths)&&max(widths)-min(widths)<1e-8)
              add('bar_width','number',as.numeric(widths[1]),min=.01,max=5,step=.02,unit='data units')
          }
        } else if(inherits(p$layers[[d$layer]]$geom,'GeomErrorbar')) {
          role<-'errorbar';add('capsize','number',p$layers[[d$layer]]$geom_params$width %||% first_value('width',.5),min=0,max=3,step=.02,unit='data units')
          add('linestyle','enum',fixed$linetype %||% 'solid',options=list('solid','dashed','dotted','dashdot'))
        }
        else add('linestyle','enum',fixed$linetype %||% 'solid',options=list('solid','dashed','dotted','dashdot'))
      }
    }
    # Native per-parameter controls: never make a visual edit require hand-written JSON.
    # Skip non-visual/data/stat controls and parameters already owned by the normal controls.
    if(!is.null(d$layer)) {
      layer<-p$layers[[d$layer]]; geom<-layer$geom_params; aes<-layer$aes_params; pos<-layer$position
      geom_function<-function(layer) {
        switch(class(layer$geom)[1],GeomBar='geom_bar',GeomCol='geom_col',GeomPoint='geom_point',
          GeomErrorbar='geom_errorbar',GeomLine='geom_line',GeomPath='geom_path',GeomText='geom_text',
          GeomSegment='geom_segment',GeomRect='geom_rect',GeomTile='geom_tile',GeomArea='geom_area',
          paste0('geom_',tolower(sub('^Geom','',class(layer$geom)[1]))))
      }
      position_function<-function(position) {
        cls<-class(position)[1]
        switch(cls,PositionJitter='position_jitter',PositionJitterdodge='position_jitterdodge',
          PositionDodge='position_dodge',PositionDodge2='position_dodge2',PositionStack='position_stack',
          PositionFill='position_fill',PositionIdentity='position_identity',PositionNudge='position_nudge',
          paste0('position_',tolower(sub('^Position','',cls))))
      }
      scalar_field<-function(prop,value,domain,target) {
        if(is.null(value)||length(value)!=1||!is.atomic(value)||is.na(value)||is.function(value))return()
        field<-NULL
        if(is.logical(value))field<-list(prop=prop,type='bool',value=value,group=domain)
        else if(is.numeric(value))field<-list(prop=prop,type='number',value=as.numeric(value),min=-1e9,max=1e9,step=.1,group=domain)
        else if(is.character(value)) {
          options<-switch(sub('^.*::','',prop),lineend=c('butt','round','square'),linejoin=c('mitre','round','bevel'),orientation=c('x','y'),NULL)
          if(length(options))field<-list(prop=prop,type='enum',value=value,options=as.list(options),group=domain)
          else field<-list(prop=prop,type='text',value=value,group=domain)
        }
        if(!is.null(field)){field$r_expression<-target;fields[[length(fields)+1L]]<<-field}
      }
      r_value_field<-function(slot,key,value,domain,call) {
        prop<-paste0(slot,'::',key)
        expression_prop<-paste0('r_expr::',slot,'::',key)
        missing_scalar<-is.null(value)||(is.atomic(value)&&length(value)==1L&&is.na(value))
        expression_override<-any(vapply(patches,function(a)a$gid==d$gid&&identical(a$prop,expression_prop),logical(1)))
        # ggplot2 uses NA to mean "infer the orientation". Keep that useful
        # default as a real visual control instead of exposing the literal NA
        # expression. The writer maps `auto` back to NA.
        if(slot=='geom'&&key=='orientation') {
          orientation<-if(missing_scalar)'auto' else as.character(value)[[1]]
          if(length(orientation_options)<2L)return()
          fields[[length(fields)+1L]]<<-list(prop=prop,type='enum',value=orientation,
            options=as.list(orientation_options),group=domain,r_expression=paste0(call,'(orientation = VALUE)'))
          return()
        }
        # Keep nullable drawing parameters editable as R expressions. This is
        # how users can set an optional geom/stat/position parameter to NULL or
        # NA without adding a second, conflicting control for the same slot.
        if(missing_scalar||expression_override) {
          matching_override<-if(expression_override)Filter(function(a)a$gid==d$gid&&identical(a$prop,expression_prop),patches)else list()
          edited_value<-if(length(matching_override))matching_override[[length(matching_override)]]$value else NULL
          expr<-if(is.character(edited_value)&&length(edited_value)==1L)edited_value else literal(value)
          fields[[length(fields)+1L]]<<-list(prop=paste0('r_expr::',slot,'::',key),type='text',value=expr,
            group=domain,r_expression=paste0(call,'(',key,' = VALUE)'))
          return()
        }
        simple<-is.atomic(value)&&length(value)==1L&&!is.na(value)&&!is.function(value)
        if(simple) {scalar_field(prop,value,domain,paste0(call,'(',key,' = VALUE)'));return()}
        # Lists, vectors, NULL defaults and function-valued parameters remain
        # editable as one R expression. This is the lossless path for parameters
        # that do not fit a number/color/select control.
        expr<-literal(value)
        if(nchar(expr)>10000L)return()
        fields[[length(fields)+1L]]<<-list(prop=paste0('r_expr::',slot,'::',key),type='text',value=expr,
          group=domain,r_expression=paste0(call,'(',key,' = VALUE)'))
      }
      geom_call<-geom_function(layer)
      position_call<-position_function(pos)
      orientation_options<-c('auto','x','y')
      if(inherits(layer$geom,'GeomErrorbar')) {
        mapped<-union(names(p$mapping),names(layer$mapping))
        orientation_options<-'auto'
        if(all(c('x','ymin','ymax')%in%mapped))orientation_options<-c(orientation_options,'x')
        if(all(c('y','xmin','xmax')%in%mapped))orientation_options<-c(orientation_options,'y')
      }
      geom_owned<-if(inherits(layer$geom,'GeomBar'))'width' else if(inherits(layer$geom,'GeomErrorbar'))'width' else character()
      built_layer<-built$plot$layers[[d$layer]]
      geom_values<-geom
      for(n in names(built_layer$computed_geom_params %||% list()))if(is.null(geom_values[[n]]))geom_values[[n]]<-built_layer$computed_geom_params[[n]]
      geom_names<-unique(c(tryCatch(layer$geom$parameters(TRUE),error=function(e)character()),names(geom_values)))
      geom_style_owned<-c('colour','color','linewidth','alpha','fill','size','shape','stroke','linetype','label','angle','family','fontface','hjust','vjust','flipped_aes')
      geom_params<-setdiff(geom_names,c('na.rm',geom_owned,geom_style_owned))
      for(n in geom_params)r_value_field('geom',n,geom_values[[n]],'r_geom_params',geom_call)
      # Stat controls such as bins, binwidth, bandwidth and orientation affect
      # the rendered marks. They are distinct from data cleaning/model calls.
      stat_values<-layer$stat_params
      for(n in names(built_layer$computed_stat_params %||% list()))if(is.null(stat_values[[n]]))stat_values[[n]]<-built_layer$computed_stat_params[[n]]
      stat_names<-unique(c(tryCatch(layer$stat$parameters(TRUE),error=function(e)character()),names(stat_values)))
      for(n in setdiff(stat_names,c('na.rm','flipped_aes','')) )r_value_field('stat',n,stat_values[[n]],'r_stat_params',paste0('stat_',tolower(sub('^Stat','',class(layer$stat)[1]))))
      # These aesthetics already have one Tavotto role-native control. Excluding
      # them here prevents two widgets from writing the same ggplot aesthetic.
      aes_owned<-c('colour','color','alpha','fill','linewidth','linetype','size','shape','stroke','label','angle','family','fontface','hjust','vjust')
      if(inherits(layer$geom,c('GeomBar','GeomErrorbar')))aes_owned<-c(aes_owned,'width') # owned by bar_width / capsize
      for(n in setdiff(names(aes),aes_owned))r_value_field('aes',n,aes[[n]],'r_aes_params',geom_call)
      pos_fn<-tryCatch(get(position_call,mode='function',envir=state$env,inherits=TRUE),error=function(e)NULL)
      pos_names<-if(is.function(pos_fn))setdiff(names(formals(pos_fn)),'...') else character()
      for(n in pos_names)r_value_field('position',n,pos[[n]],'r_position_params',position_call)
      for(n in names(layer$mapping)) {
        mapped<-layer$mapping[[n]];expr<-if(rlang::is_quosure(mapped))rlang::quo_get_expr(mapped) else mapped
        text<-paste(deparse(expr,width.cutoff=500L),collapse='');prop<-paste0('mapping::layer-',d$layer,'::',n)
        add(prop,'text',text,group='r_aes_params');fields[[length(fields)]]$r_expression<-paste0('aes(',n,' = VALUE)')
      }
      add('layer::inherit.aes','bool',isTRUE(layer$inherit.aes),group='r_layer_params')
      show_legend<-if(is.null(layer$show.legend)||is.na(layer$show.legend))'auto' else if(isTRUE(layer$show.legend))'show' else 'hide'
      add('layer::show.legend','enum',show_legend,options=list('auto','show','hide'),group='r_layer_params')
    }
    # Expose the exact generated R assignment beside the corresponding common
    # inspector controls. The editor and export script consume this same map.
    if(!is.null(d$layer))for(k in seq_along(fields)) {
      f<-fields[[k]];if(!is.null(f$r_expression))next
      i<-as.integer(d$layer);prop<-f$prop
      key<-switch(prop,color='colour',facecolor='fill',alpha='alpha',linewidth='linewidth',
        markersize='size',marker='shape',markeredgewidth='stroke',linestyle='linetype',
        text='label',rotation='angle',fontfamily='family',fontweight='fontface',hjust='hjust',vjust='vjust',NULL)
      if(prop%in%c('bar_width','capsize'))f$r_expression<-paste0('p$layers[[',i,']]$geom_params$width <- VALUE')
      else if(!is.null(key)) {
        value_expr<-if(prop=='fontsize')'VALUE / (72.27 / 25.4)' else 'VALUE'
        target_key<-if(prop=='fontsize')'size' else key
        f$r_expression<-paste0('p$layers[[',i,']]$aes_params[["',target_key,'"]] <- ',value_expr)
      }
      fields[[k]]<-f
    }
    # A layer becomes tree-only only after selectable children were created.
    # A single-series or otherwise unsplit visible geom remains selectable.
    layer_element_index<-length(elements)+1L
    elements[[layer_element_index]]<-list(gid=d$gid,role=role,label=label,bbox=as.list(bx),editable=fields,draggable=movable,anchor=as.list(anchor),drag_prop='pos_frac',canvas_selectable=TRUE)
    if(split_points) {
      data<-built$data[[d$layer]];points<-one$grobs[[d$i]]$children[[d$child]];groups<-sort(unique(data$group))
      if(length(groups)>1&&all(groups>0)&&length(points$x)==nrow(data)) {
        parent_index<-length(elements);boxes<-list()
        fragments[[length(fragments)]]<-NULL
        for(group in groups) {
          rows<-which(data$group==group);part<-one;rr<-points
          for(n in c('x','y','pch','size'))if(length(rr[[n]])==nrow(data))rr[[n]]<-rr[[n]][rows]
          for(n in names(rr$gp))if(length(rr$gp[[n]])==nrow(data))rr$gp[[n]]<-rr$gp[[n]][rows]
          part$grobs[[d$i]]$children[[d$child]]<-rr
          gid<-paste0('point-group-',d$layer,'-',group);group_geometry<-point_group_geometry(data,rows)
          partpiece<-draw_piece(part,gid,geometry_bbox(group_geometry))
          fragments[[length(fragments)+1L]]<-list(gid=gid,parent=d$gid,svg=partpiece$svg)
          gb<-partpiece$bbox;if(is.null(gb))next
          boxes[[length(boxes)+1L]]<-gb
          current<-data[rows,,drop=FALSE];value<-function(n,fallback){v<-unique(current[[n]]);if(length(v)==1&&!is.na(v))v else fallback}
          name<-paste('Group',group)
          for(aesthetic in c('colour','fill')) {
            sc<-built$plot$scales$get_scales(aesthetic)
            if(!is.null(sc)&&sc$is_discrete()) {
              lv<-sc$get_limits();mapped<-unique(current[[aesthetic]]);ix<-match(mapped,sc$map(lv))
              if(length(ix)==1&&!is.na(ix)){name<-as.character(lv[ix]);break}
            }
          }
          name<-state$point_names[[gid]] %||% name;state$point_names[[gid]]<-name
          shape_value<-value('shape',19);marker<-names(point_shapes)[match(shape_value,point_shapes)];if(is.na(marker))marker<-'o'
          color_value<-value('colour','#333333')
          pf<-list(list(prop='color',type='color',value=color_value))
          if(as.numeric(shape_value)%in%21:25)pf<-c(pf,list(list(prop='facecolor',type='color',value=value('fill',color_value))))
          pf<-c(pf,list(list(prop='markersize',type='number',value=value('size',1.5),min=.1,max=15,step=.1,unit='mm'),
            list(prop='marker',type='enum',value=marker,options=as.list(names(point_shapes))),
            list(prop='markeredgewidth',type='number',value=value('stroke',.5),min=0,max=5,step=.1),
            list(prop='alpha',type='number',value=value('alpha',1),min=0,max=1,step=.05),
            list(prop='visible',type='bool',value=!any(vapply(patches,function(a)a$gid==gid&&a$prop=='visible'&&identical(a$value,FALSE),logical(1))))))
          pf<-lapply(pf,function(f){
            f$r_expression<-switch(f$prop,color='scale_colour_manual(values = VALUE)',facecolor='scale_fill_manual(values = VALUE)',
              markersize='geom_point(size = VALUE)',marker='geom_point(shape = VALUE)',markeredgewidth='geom_point(stroke = VALUE)',
              alpha='geom_point(alpha = VALUE)',visible='apply_point_groups(built, patches)')
            if(f$prop=='visible')f$primary<-TRUE
            f
          })
          group_element<-list(gid=gid,role='scatter',label=paste0('Point group "',name,'" (n=',length(rows),')'),bbox=as.list(gb),editable=pf,draggable=FALSE,canvas_selectable=TRUE)
          group_element$geometry<-group_geometry
          elements[[length(elements)+1L]]<-group_element
        }
        if(length(boxes)) {
          boxes<-do.call(rbind,boxes);lo<-apply(boxes[,1:2,drop=FALSE],2,min);hi<-apply(boxes[,1:2,drop=FALSE]+boxes[,3:4,drop=FALSE],2,max)
        elements[[parent_index]]$bbox<-as.list(c(lo,hi-lo));elements[[parent_index]]$anchor<-as.list((lo+hi)/2)
        # The parent owns whole-layer parameters; independently selectable groups
        # own only their per-series appearance. Preserve source mappings, stats and
        # non-scalar R expressions on the parent instead of dropping those controls.
        elements[[parent_index]]$editable<-point_group_parent_fields(elements[[parent_index]]$editable)
        }
      }
    }
    if(split_errorbars) {
      data<-built$data[[d$layer]];bars<-one$grobs[[d$i]]$children[[d$child]];groups<-sort(unique(data$group))
      parent_index<-which(vapply(elements,function(e)e$gid==d$gid,logical(1)))[[1]];fragments[[length(fragments)]]<-NULL
      elements[[parent_index]]$editable<-errorbar_group_parent_fields(elements[[parent_index]]$editable)
      for(q in seq_along(groups)) {
        rows<-which(data$group==groups[[q]]);part<-one;rr<-bars;ix<-which(bars$id==q)
        rr$x<-rr$x[ix];rr$y<-rr$y[ix];rr$id<-rep(1L,length(ix))
        for(n in names(rr$gp))if(length(rr$gp[[n]])==length(groups))rr$gp[[n]]<-rr$gp[[n]][q]
        part$grobs[[d$i]]$children[[d$child]]<-rr
        gid<-paste0('errorbar-group-',d$layer,'-',groups[[q]]);geom<-errorbar_group_geometry(bars,q)
        partpiece<-draw_piece(part,gid,geometry_bbox(geom));fragments[[length(fragments)+1L]]<-list(gid=gid,parent=d$gid,svg=partpiece$svg)
        gb<-partpiece$bbox;if(is.null(gb)||is.null(geom))next
        current<-data[rows,,drop=FALSE];get1<-function(n,fallback){v<-unique(current[[n]]);if(length(v)==1&&!is.na(v))v else fallback}
        style<-as.character(get1('linetype',1));style<-switch(style,'1'='solid','2'='dashed','3'='dotted','4'='dotdash',style)
        group_element<-list(gid=gid,role='errorbar',label=paste0('Error bar · ',group_label(current,paste('group',groups[[q]]))),bbox=as.list(gb),draggable=FALSE,canvas_selectable=TRUE,
          editable=list(list(prop='color',type='color',value=get1('colour','black')),
            list(prop='alpha',type='number',value=if(is.na(get1('alpha',1)))1 else get1('alpha',1),min=0,max=1,step=.05),
            list(prop='linewidth',type='number',value=get1('linewidth',.5),min=.1,max=10,step=.1,unit='mm'),
            list(prop='capsize',type='number',value=get1('width',.2),min=0,max=3,step=.02,unit='data units'),
            list(prop='linestyle',type='enum',value=style,options=list('solid','dashed','dotted','dotdash')),
            list(prop='visible',type='bool',value=TRUE)))
        group_element$editable<-lapply(group_element$editable,function(f){
          key<-switch(f$prop,color='colour',alpha='alpha',linewidth='linewidth',capsize='width',linestyle='linetype',visible='alpha')
          f$r_expression<-if(f$prop=='visible')'apply_errorbar_groups(built, patches)' else
            paste0('built$data[[',d$layer,']]$',key,'[group == ',groups[[q]],'] <- VALUE');f})
        group_element$editable[[length(group_element$editable)]]$primary<-TRUE
        group_element$geometry<-geom;elements[[length(elements)+1L]]<-group_element
      }
    }
    if(split_text) {
      data<-built$data[[d$layer]];texts<-one$grobs[[d$i]]$children[[d$child]];parent_index<-which(vapply(elements,function(e)e$gid==d$gid,logical(1)))[[1]]
      fragments[[length(fragments)]]<-NULL;elements[[parent_index]]$editable<-text_group_parent_fields(elements[[parent_index]]$editable)
      for(q in seq_len(nrow(data))) {
        part<-one;rr<-texts
        for(n in c('label','x','y','hjust','vjust','rot','check.overlap'))if(length(rr[[n]])==nrow(data))rr[[n]]<-rr[[n]][q]
        for(n in names(rr$gp))if(length(rr$gp[[n]])==nrow(data))rr$gp[[n]]<-rr$gp[[n]][q]
        part$grobs[[d$i]]$children[[d$child]]<-rr
        gid<-paste0('text-group-',d$layer,'-',q);partpiece<-draw_piece(part,gid)
        fragments[[length(fragments)+1L]]<-list(gid=gid,parent=d$gid,svg=partpiece$svg)
        gb<-partpiece$bbox;if(is.null(gb))next
        current<-data[q,,drop=FALSE];get1<-function(n,fallback){v<-current[[n]][[1]];if(is.null(v)||is.na(v))fallback else v}
        face<-get1('fontface',1);face<-if(is.numeric(face))switch(as.character(face),'1'='plain','2'='bold','3'='italic','4'='bold.italic','plain') else as.character(face)
        txt<-as.character(get1('label',''))
        if(is.finite(data$group[[q]])&&data$group[[q]]>0)txt<-paste0(txt,' · ',group_label(current,paste('group',data$group[[q]])))
        group_element<-list(gid=gid,role='text',label=txt,bbox=as.list(gb),draggable=FALSE,canvas_selectable=TRUE,
          editable=list(list(prop='text',type='text',value=as.character(current$label[[1]]),mathtext=FALSE),
            list(prop='color',type='color',value=get1('colour','black')),
            list(prop='fontsize',type='number',value=get1('size',3.88)*72.27/25.4,min=4,max=72,step=.5,unit='pt'),
            list(prop='rotation',type='number',value=get1('angle',0),min=-180,max=180,step=1),
            list(prop='fontfamily',type='enum',value=get1('family',''),options=as.list(unique(c(get1('family',''),'sans','serif','mono','Arial','Times New Roman')))),
            list(prop='fontweight',type='enum',value=face,options=list('plain','bold','italic','bold.italic')),
            list(prop='hjust',type='number',value=get1('hjust',.5),min=-2,max=3,step=.1),
            list(prop='vjust',type='number',value=get1('vjust',.5),min=-2,max=3,step=.1),
            list(prop='alpha',type='number',value=if(is.na(get1('alpha',1)))1 else get1('alpha',1),min=0,max=1,step=.05),
            list(prop='visible',type='bool',value=TRUE)))
        group_element$editable<-lapply(group_element$editable,function(f){
          key<-switch(f$prop,text='label',fontsize='size',fontfamily='family',fontweight='fontface',
            rotation='angle',color='colour',hjust='hjust',vjust='vjust',alpha='alpha',visible='alpha')
          value_expr<-if(f$prop=='fontsize')'VALUE / (72.27 / 25.4)' else if(f$prop=='fontweight')
            'match(VALUE, c("plain", "bold", "italic", "bold.italic"))' else 'VALUE'
          f$r_expression<-if(f$prop=='visible')'apply_text_groups(built, patches)' else
            paste0('built$data[[',d$layer,']]$',key,'[',q,'] <- ',value_expr);f})
        group_element$editable[[length(group_element$editable)]]$primary<-TRUE
        elements[[length(elements)+1L]]<-group_element
      }
    }
    if(!is.null(d$layer) && inherits(p$layers[[d$layer]]$geom,'GeomBar') && inherits(one$grobs[[d$i]]$children[[d$child]],'rect')) {
      sc<-built$plot$scales$get_scales('fill')
      if(!is.null(sc)&&sc$is_discrete()&&length(sc$get_limits())>1) {
        lv<-sc$get_limits();cols<-sc$map(lv);data<-built$data[[d$layer]];rect<-one$grobs[[d$i]]$children[[d$child]]
        # Only split when the rectangle vector matches the built data exactly.
        key<-as.character(d$layer)
        if(is.null(state$fill_rows[[key]])&&all(data$fill %in% cols)&&!anyDuplicated(cols))state$fill_rows[[key]]<-lapply(cols,function(c)which(data$fill==c))
        if(length(rect$x)==nrow(data)&&!is.null(state$fill_rows[[key]])) {
          parent_index<-length(elements);elements[[parent_index]]$editable<-Filter(function(f)f$prop!='facecolor',elements[[parent_index]]$editable)
          fragments[[length(fragments)]]<-NULL
          for(q in seq_along(lv)) {
            rows<-state$fill_rows[[key]][[q]];if(!length(rows))next
            part<-one;rr<-rect
            for(n in c('x','y','width','height'))if(length(rr[[n]])>1)rr[[n]]<-rr[[n]][rows]
            for(n in names(rr$gp))if(length(rr$gp[[n]])==nrow(data))rr$gp[[n]]<-rr$gp[[n]][rows]
            part$grobs[[d$i]]$children[[d$child]]<-rr
            gid<-paste0('fill-group-',d$layer,'-',q)
            rows<-state$fill_rows[[key]][[q]];group_geometry<-rect_group_geometry(data,rows)
            partpiece<-draw_piece(part,gid,geometry_bbox(group_geometry))
            fragments[[length(fragments)+1L]]<-list(gid=gid,parent=d$gid,svg=partpiece$svg)
            gb<-partpiece$bbox
            if(!is.null(gb)) {
              group_element<-list(gid=gid,role='bar',label=paste('Fill:',lv[q]),bbox=as.list(gb),editable=list(list(prop='facecolor',type='color',value=cols[q])),draggable=FALSE,canvas_selectable=TRUE)
              group_element$geometry<-group_geometry
              elements[[length(elements)+1L]]<-group_element
            }
          }
        }
      }
    }
    if(!is.null(d$layer)) {
      child_indices<-if(length(elements)>layer_element_index)seq.int(layer_element_index+1L,length(elements)) else integer()
      has_selectable_children<-any(vapply(elements[child_indices],function(element)isTRUE(element$canvas_selectable),logical(1)))
      elements[[layer_element_index]]$canvas_selectable<-!has_selectable_children
      if(!has_selectable_children) {
        data<-built$data[[d$layer]];artist<-one$grobs[[d$i]]$children[[d$child]]
        geometry<-if(inherits(artist,'points'))point_group_geometry(data,seq_len(nrow(data))) else
          if(inherits(artist,'rect'))rect_group_geometry(data,seq_len(nrow(data))) else layer_grob_geometry(artist)
        bounds<-geometry_bbox(geometry)
        if(!is.null(bounds)) {
          elements[[layer_element_index]]$geometry<-geometry
          elements[[layer_element_index]]$bbox<-as.list(bounds)
          elements[[layer_element_index]]$anchor<-as.list(bounds[1:2]+bounds[3:4]/2)
          state$anchors[[d$gid]]<-bounds[1:2]+bounds[3:4]/2
        }
      }
    }
  }
  # Each tick label is a separate selectable text artist. Its R style is still
  # owned by theme(axis.text.x/y), while the axis group retains tick values,
  # formatting and range controls.
  for(axis_gid in c('axis-b','axis-l')) {
    axis_i<-which(g$layout$name==axis_gid);if(length(axis_i)!=1)next
    axis_grob<-g$grobs[[axis_i]];axis_table<-axis_grob$children[['axis']]
    title_i<-which(vapply(axis_table$grobs,inherits,logical(1),'titleGrob'));if(length(title_i)!=1)next
    title_grob<-axis_table$grobs[[title_i]];text_i<-which(vapply(title_grob$children,inherits,logical(1),'text'));if(length(text_i)!=1)next
    full_text<-title_grob$children[[text_i]];labels<-as.character(full_text$label)
    for(q in seq_along(labels)) {
      gid<-paste0(axis_gid,'.tick-label-',q);part<-g
      for(j in setdiff(seq_along(part$grobs),axis_i))part$grobs[[j]]<-nullGrob()
      axis_part<-part$grobs[[axis_i]];axis_sub<-axis_part$children[['axis']]
      for(j in setdiff(seq_along(axis_sub$grobs),title_i))axis_sub$grobs[[j]]<-nullGrob()
      tick_title<-axis_sub$grobs[[title_i]];tick_text<-tick_title$children[[text_i]]
      for(n in c('label','x','y','hjust','vjust','rot','check.overlap'))if(length(tick_text[[n]])==length(labels))tick_text[[n]]<-tick_text[[n]][q]
      for(n in names(tick_text$gp))if(length(tick_text$gp[[n]])==length(labels))tick_text$gp[[n]]<-tick_text$gp[[n]][q]
      tick_title$children[[text_i]]<-tick_text;axis_sub$grobs[[title_i]]<-tick_title;axis_part$children[['axis']]<-axis_sub;part$grobs[[axis_i]]<-axis_part
      piece<-draw_piece(part,gid);if(is.null(piece$bbox))next
      parent<-Filter(function(e)e$gid==axis_gid,elements)[[1]]
      fields<-list(list(prop='text',type='text',value=labels[[q]],mathtext=FALSE,primary=TRUE,
        r_expression=paste0('p <- apply_visual_property(p, ',literal(gid),', "text", VALUE)')))
      elements[[length(elements)+1L]]<-list(gid=gid,role='ticklabel',label=labels[[q]],
        bbox=as.list(piece$bbox),editable=fields,draggable=FALSE,canvas_selectable=TRUE)
    }
  }
  # Expose only continuous Cartesian limits; scale transforms stay in the source R code.
  if(identical(class(p$coordinates)[1],'CoordCartesian')) {
    af<-list();pp<-built$layout$panel_params[[1]]
    for(axis in c('x','y')) {
      if(!pp[[axis]]$is_discrete()) {
        sc<-built$plot$scales$get_scales(axis);name<-sc$trans$name %||% 'identity'
        value<-switch(name,identity='linear','log-10'='log',name)
        if(value %in% c('linear','log','sqrt','reverse'))af[[length(af)+1L]]<-list(prop=paste0(axis,'scale'),type='enum',value=value,options=list('linear','log','sqrt','reverse'))
      }
    }
    if(length(af)) {
      if(!is.null(frame)) bbox<-frame/c(w,h,w,h) else {
      svg(file.path(state$out,'panel-probe.svg'),width=w/25.4,height=h/25.4)
      draw_figure(g,w,h,frame);grid.force()
      loc<-g$layout[pi,];seekViewport(paste0('panel.',loc$t,'-',loc$l,'-',loc$b,'-',loc$r))
      a<-deviceLoc(unit(0,'npc'),unit(0,'npc'),valueOnly=TRUE);b<-deviceLoc(unit(1,'npc'),unit(1,'npc'),valueOnly=TRUE);dev.off()
      bbox<-c(a$x/(w/25.4),1-b$y/(h/25.4),(b$x-a$x)/(w/25.4),(b$y-a$y)/(h/25.4))
      }
      af[[length(af)+1L]]<-list(prop='frame_mm',type='rect',value=as.list(frame),unit='mm',primary=TRUE)
      for(ax in c('x','y')) {
        grid<-ggplot2::calc_element(paste0('panel.grid.major.',ax),theme_get()+p$theme)
        af[[length(af)+1L]]<-list(prop=paste0('grid_',ax),type='bool',value=!inherits(grid,'element_blank'))
      }
      grid<-ggplot2::calc_element('panel.grid.major',theme_get()+p$theme)
      border<-ggplot2::calc_element('panel.border',theme_get()+p$theme)
      background<-ggplot2::calc_element('panel.background',theme_get()+p$theme)
      af<-c(af,list(list(prop='grid_color',type='color',value=grid$colour %||% '#cccccc'),
        list(prop='grid_linewidth',type='number',value=grid$linewidth %||% .5,min=0,max=5,step=.1,unit='mm'),
        list(prop='grid_linestyle',type='enum',value=as.character(grid$linetype %||% 'solid'),options=as.list(unique(c(as.character(grid$linetype %||% 'solid'),'solid','dashed','dotted','dotdash')))),
        list(prop='spine_color',type='color',value=border$colour %||% 'black'),
        list(prop='spine_linewidth',type='number',value=border$linewidth %||% .5,min=0,max=5,step=.1,unit='mm'),
        list(prop='facecolor',type='color',value=background$fill %||% 'white')))
      # The panel rectangle covers most of the plot and is not an actual mark.
      # Keep its controls in the tree, but never let its large area intercept canvas picks.
      elements[[length(elements)+1L]]<-list(gid='axes_0',role='axes',label='Subplot 1',bbox=as.list(bbox),editable=af,draggable=FALSE,resizable=TRUE,canvas_selectable=FALSE)
    }
  }
  figure_index<-length(elements)+1L
  elements[[figure_index]]<-list(gid='figure',role='figure',label='Figure',bbox=list(0,0,1,1),editable=list(list(prop='size_mm',type='pair',value=list(w,h),unit='mm')),draggable=FALSE,resizable=TRUE,canvas_selectable=FALSE)
  # Figure means the physical page. A label already represented by its own drawn
  # grob belongs to that text object; keep the empty-label entry here only when
  # there is no canvas object to select yet, so changing it can create the grob.
  for(name in c('title','subtitle','caption'))if(!any(vapply(elements,function(e)e$gid==name,logical(1))))
    elements[[figure_index]]$editable<-c(elements[[figure_index]]$editable,list(list(prop=name,type='text',value=as.character(plot_labels[[name]] %||% ''))))
  legend_position<-ggplot2::calc_element('legend.position',theme_get()+p$theme)
  if(is.character(legend_position))elements[[figure_index]]$editable<-c(elements[[figure_index]]$editable,list(list(prop='legend_position',type='enum',value=legend_position,options=list('none','right','left','top','bottom','inside'))))

  # Keep the upstream Tavotto object/inspector contract: one selected object
  # owns the fields that describe it. ggplot call parameters and theme are
  # source objects, not properties of the physical Figure.
  components<-figure_component_fields()
  is_theme_component<-function(f)startsWith(f$prop,'theme::')||startsWith(f$prop,'r_expr::theme::')
  theme_components<-Filter(is_theme_component,components)
  plot_components<-Filter(function(f)!is_theme_component(f),components)
  settings_element<-function(gid,role,label,editable=list())list(gid=gid,role=role,label=label,
    bbox=list(0,0,0,0),editable=editable,draggable=FALSE,canvas_selectable=FALSE)
  plot_owner<-function(field) {
    prop<-sub('^r_expr::','',field$prop)
    if(startsWith(prop,'mapping::'))return('mapping')
    if(startsWith(prop,'scale::'))return(paste0('scale-',strsplit(sub('^scale::','',prop),'::',fixed=TRUE)[[1]][[1]]))
    if(startsWith(prop,'coord::'))return('coordinate')
    if(startsWith(prop,'facet::'))return('facet')
    if(startsWith(prop,'guides::'))return(paste0('guide-',strsplit(sub('^guides::','',prop),'::',fixed=TRUE)[[1]][[1]]))
    'other'
  }
  plot_component_label<-function(owner,fields) {
    first<-fields[[1L]]
    if(owner=='mapping')return('aes() · global')
    source_constructor<-function(object,prefix) {
      call<-tryCatch(object$call,error=function(e)NULL)
      name<-if(is.call(call))paste(deparse(call[[1L]],width.cutoff=500L),collapse='')else''
      if(nzchar(name))name else paste0(prefix,tolower(sub('^(Coord|Facet)','',class(object)[[1L]])))
    }
    if(owner=='coordinate')return(paste0(source_constructor(p$coordinates,'coord_'),'()'))
    if(owner=='facet')return(paste0(source_constructor(p$facet,'facet_'),'()'))
    if(startsWith(owner,'scale-'))return(sub('\\(.*$','',first$r_expression %||% paste0('scale ',sub('^scale-','',owner))))
    if(startsWith(owner,'guide-'))return(paste0('guide(',sub('^guide-','',owner),')'))
    owner
  }
  if(length(plot_components)) {
    elements[[length(elements)+1L]]<-settings_element('figure.ggplot','r_plot_settings','ggplot() settings')
    plot_owners<-unique(vapply(plot_components,plot_owner,character(1)))
    for(owner in plot_owners) {
      fields<-Filter(function(f)identical(plot_owner(f),owner),plot_components)
      elements[[length(elements)+1L]]<-settings_element(paste0('figure.ggplot.',owner),'r_plot_settings',plot_component_label(owner,fields),fields)
    }
  }
  if(length(theme_components)) {
    elements[[length(elements)+1L]]<-settings_element('figure.theme','r_theme_settings','theme() settings')
    theme_name<-function(field)sub('^r_theme_element::','',field$group %||% 'theme')
    theme_owners<-unique(vapply(theme_components,theme_name,character(1)))
    for(name in theme_owners) {
      fields<-Filter(function(f)identical(theme_name(f),name),theme_components)
      slug<-gsub('[^[:alnum:]_-]+','_',name)
      elements[[length(elements)+1L]]<-settings_element(paste0('figure.theme.element_',slug),'r_theme_settings',paste0('theme(',name,')'),fields)
    }
  }
  for(e in elements)state$capabilities[[e$gid]]<-e
  state$base_g<-g
  for(i in seq_along(elements))elements[[i]]$r_native<-TRUE
  source_script<-state$env$tavotto_provenance$source_script %||% state$script
  state$manifest<-list(stem='R-figure',size_mm=list(w,h),elements=elements,source_script=source_script)
  state$patches<-patches;state$rev<-state$rev+1L
  list(ok=TRUE,rev=state$rev,manifest=state$manifest,fragments=fragments,warnings=warnings,patches=patches,object=state$object,source_runs=1L,cache=list(hits=cache_hits,misses=cache_misses))
}
export_figure<-function(generate_files=TRUE){
  g<-state$g;patches<-state$patches;w<-state$w;h<-state$h
  if(is.null(g))stop('Open a figure first')
  if(isTRUE(generate_files)) {
    grDevices::png(file.path(state$out,'figure.png'),width=round(w/25.4*600),height=round(h/25.4*600),res=600,type='cairo',bg='white');draw_figure(g,w,h,state$frame);grDevices::dev.off()
    grDevices::cairo_pdf(file.path(state$out,'figure.pdf'),width=w/25.4,height=h/25.4);draw_figure(g,w,h,state$frame);grDevices::dev.off()
    grDevices::svg(file.path(state$out,'figure.svg'),width=w/25.4,height=h/25.4,bg='transparent');draw_figure(g,w,h,state$frame);grDevices::dev.off()
  }
  writeLines(toJSON(patches,auto_unbox=TRUE,null='null'),file.path(state$out,'patches.json'))
  # Reproduction contains ordinary R expressions plus grid layout edits, no app dependency.
  replay_script<-if(browser_mode)sub('^/project/','',state$script) else state$script
  replay_directory<-dirname(replay_script)
  replay_filename<-if(browser_mode)basename(replay_script) else replay_script
  if(browser_mode&&isTRUE(state$browser_captured_object))saveRDS(state$p,file.path(state$out,'figure-source.rds'))
  code<-c('# Edited with Tavotto R. The original analysis script is preserved.', 'library(ggplot2); library(grid)',"if(.Platform$OS.type=='windows')invisible(try(Sys.setlocale('LC_CTYPE','English_United States.utf8'),silent=TRUE)); options(encoding='UTF-8')",paste0('setwd(',literal(replay_directory),')'),paste0('source(',literal(replay_filename),', local=TRUE)'),paste0('p <- get(',literal(state$object),')'),paste0('normalize_tavotto_markdown <- ',literal(normalize_tavotto_markdown)),'p <- normalize_tavotto_markdown(p, force=TRUE)',paste0('superscript_minus_plotmath <- ',literal(superscript_minus_plotmath)),paste0('render_superscript_minus_labels <- ',literal(render_superscript_minus_labels)),'', '# Visual adjustments as native R expressions')
  if(browser_mode&&isTRUE(state$browser_captured_object))code<-c(code[1:3],
    '# This plot was local to a function or export call; its original native ggplot object is preserved.',
    'p <- readRDS("figure-source.rds")',code[7:length(code)])
  labels<-c(title='title',subtitle='subtitle',caption='caption','xlab-b'='x','ylab-l'='y')
  themes<-c(title='plot.title',subtitle='plot.subtitle',caption='plot.caption','xlab-b'='axis.title.x','ylab-l'='axis.title.y','axis-b'='axis.text.x','axis-l'='axis.text.y')
  palette<-FALSE
  visual_helper<-FALSE
  for(a in patches) {
    id<-a$gid;prop<-a$prop;v<-a$value
    tick_label_text<-grepl('^axis-[bl][.]tick-label-[0-9]+$',id)&&prop=='text'
    if(grepl('^axis-[bl][.]tick-label-[0-9]+$',id)&&!tick_label_text)id<-sub('[.]tick-label-[0-9]+$','',id)
    if(prop %in% c('major_step','major_values')) {
      modes<-Filter(function(x)x$gid==id&&x$prop=='major_mode',patches)
      if(length(modes)) {
        mode<-modes[[length(modes)]]$value
        if(mode=='auto'||(mode=='fixed'&&prop=='major_step')||(mode=='step'&&prop=='major_values'))next
      }
    }
    line<-NULL
    if(tick_label_text) {
      visual_helper<-TRUE
      line<-paste0('p <- apply_visual_property(p, ',literal(id),', "text", ',literal(v),')')
    } else if(id %in% names(labels)&&prop=='text')line<-paste0('p <- p + labs(',labels[[id]],' = ',literal(v),')')
    else if(id %in% names(themes)&&prop %in% c('fontsize','color','fontweight','rotation','fontfamily')) {
      key<-switch(prop,fontsize='size',color='colour',fontweight='face',rotation='angle',fontfamily='family')
      if(prop=='fontweight')v<-if(v=='bold')'bold' else 'plain'
      line<-paste0('p <- p + theme(',themes[[id]],' = element_text(',key,' = ',literal(v),'))')
    } else if(id=='axes_0'&&prop %in% c('xlim','ylim'))line<-paste0('p$coordinates$limits$',if(prop=='xlim')'x' else 'y',' <- ',literal(unlist(v)))
    else if(startsWith(id,'layer-')&&prop%in%c('bar_width','capsize'))line<-paste0('p$layers[[',as.integer(sub('layer-','',id)),']]$geom_params$width <- ',literal(v))
    else if(startsWith(id,'guide-box')&&prop=='fontsize')line<-paste0('p <- p + theme(legend.text = element_text(size = ',literal(v),'), legend.title = element_text(size = ',literal(v),'))')
    else if(startsWith(id,'fill-group-')&&prop=='facecolor')palette<-TRUE
    else if(startsWith(id,'layer-')&&prop %in% c('color','linewidth','alpha','markersize','facecolor','text','fontsize','rotation','linestyle')) {
      i<-as.integer(sub('layer-','',id));key<-switch(prop,color='colour',markersize='size',facecolor='fill',text='label',fontsize='size',rotation='angle',linestyle='linetype',prop)
      if(prop=='fontsize')v<-v/(72.27/25.4)
      if(prop=='linestyle')v<-switch(v,solid='solid',dashed='dashed',dotted='dotted',dashdot='dotdash',v)
      mapped<-!is.null(state$p$layers[[i]]$mapping[[key]])||(isTRUE(state$p$layers[[i]]$inherit.aes)&&!is.null(state$p$mapping[[key]]))
      if(prop=='facecolor'&&mapped&&inherits(state$p$layers[[i]]$geom,'GeomBar'))palette<-TRUE else line<-paste0('p$layers[[',i,']]$aes_params[[',literal(key),']] <- ',literal(v))
    }
    if(is.null(line)&&!startsWith(id,'point-group-')&&!is.null(apply_visual_property(unserialize(serialize(state$p,NULL)),id,prop,v,env=state$env))) {
      visual_helper<-TRUE
      explicit_point_fill<-prop=='marker'&&any(vapply(patches,function(change)identical(change$gid,id)&&identical(change$prop,'facecolor'),logical(1)))
      line<-paste0('p <- apply_visual_property(p, ',literal(id),', ',literal(prop),', ',literal(a$value),
        if(explicit_point_fill)', preserve_empty_fill = TRUE' else '',')')
    }
    if(!is.null(line))code<-c(code,line)
  }
  if(palette) {
    sc<-ggplot_build(apply_plot(state$p,patches))$plot$scales$get_scales('fill');lv<-sc$get_limits()
    code<-c(code,paste0('p <- p + scale_fill_manual(values = ',literal(setNames(sc$map(lv),lv)),')'))
  }
  if(any(vapply(patches,function(a)a$prop=='pos_frac',logical(1))))code<-c(code,paste0('move_grob <- ',literal(move_grob)),paste0('move_element <- ',literal(move_element)))
  if(any(vapply(patches,function(a)a$prop=='visible'&&identical(a$value,FALSE)&&!grepl('^(point|errorbar|text)-group-',a$gid),logical(1))))code<-c(code,paste0('hide_element <- ',literal(hide_element)))
  if(visual_helper)code<-append(code,c(paste0('point_shapes <- ',literal(point_shapes)),
    paste0('default_guide <- ',literal(default_guide)),paste0('clone_component <- ',literal(clone_component)),
    paste0('apply_visual_property <- ',literal(apply_visual_property))),after=2)
  group_patches<-Filter(function(a)startsWith(a$gid,'point-group-'),patches)
  if(length(group_patches))code<-c(code,paste0('point_shapes <- ',literal(point_shapes)),paste0('apply_point_groups <- ',literal(apply_point_groups)))
  errorbar_patches<-Filter(function(a)startsWith(a$gid,'errorbar-group-'),patches)
  if(length(errorbar_patches))code<-c(code,paste0('apply_errorbar_groups <- ',literal(apply_errorbar_groups)))
  text_patches<-Filter(function(a)startsWith(a$gid,'text-group-'),patches)
  if(length(text_patches))code<-c(code,paste0('apply_text_groups <- ',literal(apply_text_groups)))
  code<-c(code,'p <- render_superscript_minus_labels(p)','', '# Draw using R grid; change the output path here.',paste0('svg("figure-replayed.svg",width=',w/25.4,',height=',h/25.4,',bg="transparent")'),'set.seed(20260922)','built <- ggplot_build(p)')
  if(length(group_patches))code<-c(code,paste0('built <- apply_point_groups(built, ',literal(group_patches),')'))
  if(length(errorbar_patches))code<-c(code,paste0('built <- apply_errorbar_groups(built, ',literal(errorbar_patches),')'))
  if(length(text_patches))code<-c(code,paste0('built <- apply_text_groups(built, ',literal(text_patches),')'))
  code<-c(code,'g <- ggplot_gtable(built)')
  for(a in patches)if(a$prop=='pos_frac') {v<-unlist(a$value)-state$anchors[[a$gid]];code<-c(code,paste0('g <- move_element(g,',literal(a$gid),',',v[1]*w,',',v[2]*h,')'))}
  for(a in patches)if(a$prop=='visible'&&identical(a$value,FALSE)&&!grepl('^(point|errorbar|text)-group-',a$gid))code<-c(code,paste0('g <- hide_element(g,',literal(a$gid),')'))
  code<-c(code,paste0('draw_figure <- ',literal(draw_figure)),paste0('draw_figure(g,',literal(w),',',literal(h),',',literal(state$frame),');dev.off()'));writeLines(code,file.path(state$out,'figure-edited.R'))
  list(ok=TRUE)
}
handle<-function(req) {
  if(req$method=='open') {
    state$script<-normalizePath(req$script,winslash='/',mustWork=TRUE);state$object<-req$object %||% 'tavotto_plot'
    state$frame<-NULL;state$default_frame_mm<-NULL;state$source_frame_mm<-NULL
    state$out<-req$out;dir.create(state$out,recursive=TRUE,showWarnings=FALSE)
    env<-new.env(parent=globalenv());state$env<-env;old<-getwd();setwd(dirname(state$script));on.exit(setwd(old))
    # Parse the original script, narrowly redirect its graphics output folder,
    # and replace unqualified package installers in the parsed copy. The source
    # file itself is never rewritten; the AST replacement survives rm(list=ls()).
    safe_source<-source_page_geometry(state$script,state$out)
    state$source_page_mm<-safe_source$size_mm
    # Capture user print() output so it cannot corrupt the protocol.
    capture.output(for (expression in safe_source$expressions) eval(expression,envir=env),
      file=file.path(state$out,'script.log'))
    # A cached RDS is a standalone exported figure, not the entire source
    # composition. Its own saved layout/geometry sidecar is authoritative;
    # the provenance source may describe a multi-panel page and must not be
    # used to size this one cached panel.
    provenance<-if(exists('tavotto_provenance',env,inherits=FALSE))get('tavotto_provenance',env,inherits=FALSE) else NULL
    state$cached_render_state<-is.list(provenance)&&identical(provenance$mode,'cached_render_state')
    cached_geometry<-if(state$cached_render_state)cached_render_geometry(provenance) else NULL
    if(state$cached_render_state) {
      state$source_page_mm<-cached_geometry$page_mm %||% NULL
    }
    if(browser_mode) {
      public_plots<-Filter(function(n)tryCatch(inherits(get(n,env),'ggplot')&&!inherits(get(n,env),'patchwork'),error=function(e)FALSE),ls(env))
      for(i in seq_along(state$browser_exports)) {
        candidate<-state$browser_exports[[i]]$plot
        if(inherits(candidate,'ggplot')&&!inherits(candidate,'patchwork')&&
          !any(vapply(public_plots,function(n)identical(get(n,env),candidate),logical(1))))
          assign(paste0('.tavotto_export_',i),candidate,envir=env)
      }
    }
    state$safe_source<-safe_source;state$cached_geometry<-cached_geometry
    return(select_opened_plot(req))
  } else if(req$method=='select')select_opened_plot(req)
  else if(req$method=='apply')render(req$patches %||% list())
  else if(req$method=='code')export_figure(generate_files=FALSE)
  else if(req$method=='export')export_figure() else stop('Unknown method')
}
select_opened_plot <- function(req) {
    env<-state$env;safe_source<-state$safe_source;cached_geometry<-state$cached_geometry
    if(is.null(env))stop('Open a script first')
    if(!is.null(req$object))state$object<-req$object
    plots<-Filter(function(n)tryCatch(inherits(get(n,env),'ggplot')&&!inherits(get(n,env),'patchwork'),error=function(e)FALSE),ls(env,all.names=browser_mode))
    if(!exists(state$object,env,inherits=FALSE)){
      if(length(plots)==1&&state$object=='tavotto_plot')state$object<-plots[[1]]
      else if(browser_mode&&length(plots)>1)return(list(ok=TRUE,needs_object=TRUE,objects=unname(as.list(plots))))
      else stop('Choose a ggplot object. Available: ',paste(plots,collapse=', '))
    }
    state$p<-get(state$object,env);if(!inherits(state$p,'ggplot')||inherits(state$p,'patchwork'))stop('Select a single ggplot object')
    state$browser_captured_object<-browser_mode&&grepl('^[.]tavotto_export_[0-9]+$',state$object)
    state$layout<-if(exists('tavotto_layout',env,inherits=FALSE))get('tavotto_layout',env) else list()
    if(state$cached_render_state&&!is.null(cached_geometry$frame_mm)&&is.null(state$layout$frame_mm))
      state$layout$frame_mm<-cached_geometry$frame_mm
    if(browser_mode)state$source_page_mm<-browser_export_size(state$p)
    page_size<-state$source_page_mm %||% state$layout$size_mm
    if(is.null(page_size)&&browser_mode&&!is.null(req$fallback_size_px))page_size<-as.numeric(unlist(req$fallback_size_px))*25.4/96
    if(is.null(page_size)&&browser_mode)return(list(ok=TRUE,needs_size=TRUE,object=state$object,
      reason=if(isTRUE(state$browser_size_conflict))'conflicting_export_sizes' else 'missing_export_size'))
    if(is.null(page_size))stop('No explicit graphics export size was found in the selected script or the cached figure metadata. The cached source script is never executed to guess a size; define its R device width/height or an explicit tavotto_layout$size_mm fallback.')
    stopifnot(length(page_size)==2,is.numeric(page_size),all(is.finite(page_size)),all(page_size>0),all(page_size<=PAGE_SIZE_MAX_MM))
    state$page_size_mm<-as.numeric(page_size);state$w<-state$page_size_mm[[1L]];state$h<-state$page_size_mm[[2L]]
    # A script's explicit device size is authoritative. tavotto_layout$size_mm
    # is only consulted above when the source has no static output dimensions.
    if(!is.null(state$layout$frame_mm))stopifnot(length(state$layout$frame_mm)==4,all(is.finite(state$layout$frame_mm)),all(state$layout$frame_mm[3:4]>0))
    state$source_frame_mm<-if(!is.null(state$layout$frame_mm)||state$cached_render_state)NULL else measure_patchwork_panel(state$p,env,state$page_size_mm,safe_source$expressions,state$object)
    state$base_result<-NULL;state$styles<-NULL;state$anchors<-list();state$fill_rows<-list();state$pieces<-list();state$background_key<-NULL;state$point_names<-list();state$capabilities<-list();state$manifest<-list(elements=list());render()
}
tavotto_handle_json <- function(line) {
  before_request<-as.list(state,all.names=TRUE)
  warning_messages<-character()
  result<-tryCatch(withCallingHandlers(handle(fromJSON(line,simplifyVector=FALSE)),warning=function(w) {
    warning_messages<<-c(warning_messages,conditionMessage(w));invokeRestart('muffleWarning')
  }),error=function(e){
    rm(list=setdiff(ls(state,all.names=TRUE),names(before_request)),envir=state)
    list2env(before_request,envir=state)
    while(dev.cur()>1)dev.off()
    list(ok=FALSE,error=paste(c(conditionMessage(e),tail(unique(warning_messages),3L)),collapse='\n'))
  })
  if(isTRUE(result$ok)&&length(warning_messages))result$warnings<-as.list(unique(c(unlist(result$warnings),warning_messages)))
  toJSON(result,auto_unbox=TRUE,null='null',digits=12)
}
if(!browser_mode) {
  input<-file('stdin','r')
  repeat {
    line<-readLines(input,n=1,warn=FALSE);if(!length(line))break
    cat(tavotto_handle_json(line),'\n');flush.console()
  }
}
