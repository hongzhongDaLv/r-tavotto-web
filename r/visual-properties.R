# Native ggplot/grid property adapters shared by the live engine and R replay.
point_shapes <- c(o=21,s=22,'^'=24,v=25,D=23,'+'=3,x=4,'*'=8)
default_guide <- function(p,aesthetic) {
  scale<-p$scales$get_scales(aesthetic)
  if(!is.null(scale)&&!scale$is_discrete()&&aesthetic%in%c('fill','colour','color'))ggplot2::guide_colourbar() else ggplot2::guide_legend()
}
clone_component <- function(x) {
  clone<-tryCatch(x$clone,error=function(e)NULL)
  if(is.function(clone))return(tryCatch(clone(deep=TRUE),error=function(e)unserialize(serialize(x,NULL))))
  unserialize(serialize(x,NULL))
}
superscript_minus_plotmath <- function(label) {
  # Arial on Windows does not contain U+207B (SUPERSCRIPT MINUS). R's SVG
  # device emits a tofu box for that single character. Represent a unit such
  # as kg⁻¹ with plotmath's ASCII minus, while keeping the plain Unicode label
  # in the editor and object manifest.
  if(!is.character(label)||length(label)!=1L||is.na(label))return(label)
  pattern <- '([[:alpha:]][[:alnum:]]*)⁻([⁰¹²³⁴⁵⁶⁷⁸⁹]+)'
  matches <- gregexpr(pattern,label,perl=TRUE)[[1L]]
  if(length(matches)==1L&&matches[[1L]]<0L)return(label)
  lengths <- attr(matches,'match.length')
  digits <- setNames(as.character(0:9),c('⁰','¹','²','³','⁴','⁵','⁶','⁷','⁸','⁹'))
  parts <- list();cursor <- 1L
  for(i in seq_along(matches)) {
    start <- matches[[i]];end <- start+lengths[[i]]-1L
    if(start>cursor)parts[[length(parts)+1L]] <- substring(label,cursor,start-1L)
    token <- substring(label,start,end)
    captures <- regmatches(token,regexec(pattern,token,perl=TRUE))[[1L]]
    exponent_digits <- captures[[3L]]
    # `strsplit(x, "")` may split UTF-8 superscript glyphs into bytes on
    # Windows R. Replace each complete glyph as text instead.
    for(j in seq_along(digits))exponent_digits<-gsub(names(digits)[[j]],digits[[j]],exponent_digits,fixed=TRUE)
    exponent <- paste0('-',exponent_digits)
    parts[[length(parts)+1L]] <- parse(text=paste0('plain(',captures[[2L]],')^',exponent))[[1L]]
    cursor <- end+1L
  }
  if(cursor<=nchar(label))parts[[length(parts)+1L]] <- substring(label,cursor)
  if(length(parts)==1L&&is.language(parts[[1L]]))return(as.expression(parts[[1L]]))
  as.expression(as.call(c(list(as.name('paste')),parts,list(sep=''))))
}
render_superscript_minus_labels <- function(p) {
  if(!inherits(p,'ggplot'))return(p)
  for(key in names(p$labels)) {
    label <- p$labels[[key]]
    if(is.character(label)&&length(label)==1L)p$labels[[key]] <- superscript_minus_plotmath(label)
  }
  p
}
r_native_expression <- function(x) {
  # ggplot2 margins are S7/grid units. deparse() serializes their S7 class
  # definition (including constructor functions), turning one editable margin
  # into a huge, misleading expression. Emit the native constructor instead.
  if(inherits(x,'ggplot2::margin')&&length(x)==4L) {
    values<-as.numeric(x);types<-tryCatch(grid::unitType(x),error=function(e)character())
    if(length(types)==4L&&length(unique(types))==1L) {
      unit<-switch(types[[1]],points='pt',lines='lines',cm='cm',mm='mm',inches='in',NA_character_)
      if(!is.na(unit)) {
        args<-c('t','r','b','l')
        nums<-format(values,digits=15L,trim=TRUE,scientific=FALSE)
        return(paste0('ggplot2::margin(',paste(paste0(args,' = ',nums),collapse=', '),', unit = ',dQuote(unit),')'))
      }
    }
  }
  paste(deparse(x,width.cutoff=500L),collapse='\n')
}
normalize_tavotto_markdown <- function(p,force=FALSE) {
  # Source scripts can outlive optional markdown-renderer versions. Keep source
  # untouched, but normalize labels and theme elements to deterministic grid
  # text when requested so an incompatible commonmark/ggtext pair cannot blank
  # an otherwise editable figure.
  if(!inherits(p,'ggplot')||(!force&&requireNamespace('ggtext',quietly=TRUE)))return(p)
  markup_pattern<-'<(sup|sub)>([^<]*)</(sup|sub)>'
  display_labels<-p$labels
  mapped_label<-function(label) {
    matches<-gregexpr(markup_pattern,label,ignore.case=TRUE,perl=TRUE)[[1L]]
    if(length(matches)==1L&&matches[[1L]]<0L)return(list(expression=label,display=label))
    lengths<-attr(matches,'match.length');parts<-list();display_parts<-character();cursor<-1L
    for(i in seq_along(matches)) {
      start<-matches[[i]];end<-start+lengths[[i]]-1L;before<-substring(label,cursor,start-1L);display_before<-before
      token_match<-if(nchar(before))regexpr('[[:alpha:]][[:alnum:].]*$',before,perl=TRUE)else -1L
      base<-if(length(token_match)&&token_match[[1L]]>0L)regmatches(before,token_match)else''
      if(nchar(base))before<-substring(before,1L,token_match[[1L]]-1L)
      if(nchar(before))parts[[length(parts)+1L]]<-before
      if(nchar(display_before))display_parts<-c(display_parts,display_before)
      token<-substring(label,start,end);capture<-regmatches(token,regexec(markup_pattern,token,ignore.case=TRUE,perl=TRUE))[[1L]]
      kind<-tolower(capture[[2L]]);content<-capture[[3L]]
      valid<-kind==tolower(capture[[4L]])&&grepl('^[[:alnum:]+.−-]+$',content,perl=TRUE)
      if(valid&&(nchar(base)||length(parts)&&is.language(parts[[length(parts)]]))) {
        operand<-if(grepl('^[-+]?[0-9]+([.][0-9]+)?$',content))parse(text=content)[[1L]]else content
        target<-if(nchar(base))as.call(list(as.name('plain'),as.name(base)))else parts[[length(parts)]]
        expression<-as.call(list(as.name(if(kind=='sup')'^'else'['),target,operand))
        if(!nchar(base))parts[[length(parts)]]<-expression else parts[[length(parts)+1L]]<-expression
      }else parts[[length(parts)+1L]]<-content
      mapping<-if(kind=='sup')c(setNames(c('⁰','¹','²','³','⁴','⁵','⁶','⁷','⁸','⁹'),as.character(0:9)),'-'='⁻','−'='⁻','+'='⁺')else c(setNames(c('₀','₁','₂','₃','₄','₅','₆','₇','₈','₉'),as.character(0:9)),'-'='₋','−'='₋','+'='₊')
      display_content<-content
      for(character in names(mapping))display_content<-gsub(character,mapping[[character]],display_content,fixed=TRUE)
      display_parts<-c(display_parts,display_content);cursor<-end+1L
    }
    after<-substring(label,cursor)
    if(nchar(after)){parts[[length(parts)+1L]]<-after;display_parts<-c(display_parts,after)}
    display<-paste0(display_parts,collapse='');display<-gsub('<br\\s*/?>',' ',display,ignore.case=TRUE,perl=TRUE);display<-gsub('<[^>]*>','',display,perl=TRUE)
    expression<-if(length(parts)==1L&&is.language(parts[[1L]]))as.expression(parts[[1L]])else as.expression(as.call(c(list(as.name('paste')),parts,list(sep=''))))
    list(expression=expression,display=display)
  }
  for(key in names(p$labels)) {
    label<-p$labels[[key]]
    if(!is.character(label)||length(label)!=1L||is.na(label)||!grepl('<(sup|sub)>',label,ignore.case=TRUE,perl=TRUE))next
    converted<-mapped_label(label);display_labels[[key]]<-converted$display;p$labels[[key]]<-converted$expression
  }
  attr(p,'tavotto_display_labels')<-display_labels
  text_fields<-c('family','face','size','colour','hjust','vjust','angle','lineheight','margin','debug','inherit.blank')
  for(key in names(p$theme)) {
    element<-p$theme[[key]]
    if(inherits(element,'element_markdown'))p$theme[[key]]<-do.call(ggplot2::element_text,element[intersect(text_fields,names(element))])
  }
  p
}
axis_limits <- function(p,built,axis) {
  explicit<-p$coordinates$limits[[axis]]
  if(!is.null(explicit))return(explicit)
  pp<-built$layout$panel_params[[1]][[axis]]
  if(pp$is_discrete())return(pp$continuous_range)
  sc<-built$plot$scales$get_scales(axis)
  if(!is.null(sc$trans))sc$trans$inverse(pp$limits) else pp$limits
}
apply_visual_property <- function(p,id,prop,v,env=parent.frame(),preserve_empty_fill=FALSE) {
  set_theme<-function(name,value) p+do.call(theme,setNames(list(value),name))
  replace_tick_label<-function(p,axis,index,value) {
    built_now<-ggplot_build(p);pp<-built_now$layout$panel_params[[1]][[axis]]
    breaks<-pp$breaks;labels<-as.character(pp$get_labels())
    if(index<1L||index>length(labels))stop('Tick label no longer exists on this axis')
    labels[[index]]<-as.character(value)
    sc<-p$scales$get_scales(axis)
    if(is.null(sc)) {
      scale_type<-if(pp$is_discrete())'discrete' else 'continuous'
      p<-p+do.call(get(paste0('scale_',axis,'_',scale_type),asNamespace('ggplot2')),list())
      sc<-p$scales$get_scales(axis)
    }
    prior<-sc$labels;discrete<-sc$is_discrete()
    formatter<-if(discrete)NULL else sc$trans$format
    keys<-as.character(breaks);values<-labels
    sc$labels<-local({
      old_labels<-prior;is_discrete<-discrete;format_breaks<-formatter
      edited_breaks<-keys;edited_labels<-values
      function(breaks) {
        key<-as.character(breaks)
        out<-if(is_discrete)key else as.character(format_breaks(breaks))
        if(is.function(old_labels))out<-as.character(old_labels(breaks))
        else if(!inherits(old_labels,'waiver')&&!is.null(old_labels)) {
          old<-as.character(old_labels)
          if(!is.null(names(old_labels))) {
            ix<-match(key,names(old_labels));hit<-which(!is.na(ix));out[hit]<-old[ix[hit]]
          } else if(length(old)==length(edited_breaks)) {
            ix<-match(key,edited_breaks);hit<-which(!is.na(ix));out[hit]<-old[ix[hit]]
          }
        }
        ix<-match(key,edited_breaks);hit<-which(!is.na(ix));out[hit]<-edited_labels[ix[hit]]
        out
      }
    })
    p
  }
  # R expressions are used only for non-scalar ggplot parameters (for example
  # scale labels, breaks, and units). Evaluate them in the source script's
  # environment so user-defined functions and symbols keep their meaning.
  expression_value<-function(text,env) {
    if(!is.character(text)||length(text)!=1||nchar(text)>10000)stop('Invalid R parameter expression')
    parsed<-parse(text=text,keep.source=FALSE)
    if(length(parsed)!=1)stop('Enter one R expression')
    eval(parsed[[1]],envir=env)
  }
  replace_theme_component<-function(name,key,value,whole=FALSE) {
    if(whole)return(p+do.call(theme,setNames(list(value),name)))
    old<-p$theme[[name]]
    if(is.null(old))old<-ggplot2::calc_element(name,theme_get()+p$theme)
    if(inherits(old,'element_blank'))old<-switch(if(grepl('text|title|strip|legend',name))'element_text' else if(grepl('background|panel|plot|legend',name))'element_rect' else 'element_line',element_text=element_text(),element_line=element_line(),element_rect=element_rect())
    s7_class<-tryCatch(S7::S7_class(old),error=function(e)NULL)
    if(!is.null(s7_class)) {
      if(!key%in%names(S7::props(old)))stop('Unknown theme element parameter: ',name,'::',key)
      rebuilt<-do.call(S7::set_props,c(list(object=old),setNames(list(value),key)))
    } else {
      if(!is.list(old)||!key%in%names(old))stop('Unknown theme element parameter: ',name,'::',key)
      old[[key]]<-value;rebuilt<-old
    }
    p+do.call(theme,setNames(list(rebuilt),name))
  }
  if(startsWith(prop,'r_expr::')) {
    bits<-strsplit(sub('^r_expr::','',prop),'::',fixed=TRUE)[[1]]
    if(length(bits)<2)stop('Invalid R parameter path')
    slot<-bits[[1]];key<-paste(bits[-1],collapse='::');value<-expression_value(v,env)
    if(slot %in% c('geom','stat','aes','position')) {
      i<-as.integer(sub('layer-','',id));if(is.na(i)||i<1||i>length(p$layers))stop('Unknown ggplot layer')
      p$layers[[i]]<-clone_component(p$layers[[i]])
      field<-switch(slot,geom='geom_params',stat='stat_params',aes='aes_params',position='position')
      if(slot=='position')p$layers[[i]]$position[[key]]<-value else p$layers[[i]][[field]][[key]]<-value
      return(p)
    }
    if(slot=='scale') {
      i<-as.integer(bits[[2]]);key<-paste(bits[-c(1,2)],collapse='::')
      if(is.na(i)||i<1||i>length(p$scales$scales)||!nzchar(key))stop('Unknown ggplot scale parameter')
      p$scales<-clone_component(p$scales)
      p$scales$scales[[i]]<-clone_component(p$scales$scales[[i]])
      if(key=='transform') {value<-scales::as.transform(value);key<-'trans'}
      p$scales$scales[[i]][[key]]<-value;return(p)
    }
    if(slot=='guides') {
      if(length(bits)<3)stop('Invalid guide parameter path')
      aesthetic<-bits[[2]];key<-paste(bits[-c(1,2)],collapse='::')
      p$guides<-clone_component(p$guides)
      if(is.null(p$guides$guides[[aesthetic]]))p$guides$guides[[aesthetic]]<-default_guide(p,aesthetic)
      else p$guides$guides[[aesthetic]]<-clone_component(p$guides$guides[[aesthetic]])
      p$guides$guides[[aesthetic]]$params[[key]]<-value;return(p)
    }
    if(slot=='coord') {
      p$coordinates<-clone_component(p$coordinates)
      if(identical(class(p$coordinates)[1],'CoordCartesian')&&key%in%c('xlim','ylim'))p$coordinates$limits[[if(key=='xlim')'x'else'y']]<-value
      else p$coordinates[[key]]<-value
      return(p)
    }
    if(slot=='facet') {p$facet<-clone_component(p$facet);p$facet$params[[key]]<-value;return(p)}
    if(slot=='theme') {
      name<-bits[[2]];key<-paste(bits[-c(1,2)],collapse='::')
      return(replace_theme_component(name,key,value,whole=key=='element'))
    }
    stop('Unsupported R parameter component: ',slot)
  }
  if(startsWith(prop,'stat::')) {key<-sub('^stat::','',prop);i<-as.integer(sub('layer-','',id));p$layers[[i]]<-clone_component(p$layers[[i]]);p$layers[[i]]$stat_params[[key]]<-v;return(p)}
  if(startsWith(prop,'layer::')) {
    key<-sub('^layer::','',prop);i<-as.integer(sub('layer-','',id))
    if(!key%in%c('inherit.aes','show.legend'))stop('Unsupported layer control: ',key)
    p$layers[[i]]<-clone_component(p$layers[[i]])
    if(key=='show.legend')v<-switch(v,auto=NA,show=TRUE,hide=FALSE,v)
    p$layers[[i]][[key]]<-v;return(p)
  }
  if(startsWith(prop,'scale::')) {
    bits<-strsplit(sub('^scale::','',prop),'::',fixed=TRUE)[[1]];i<-as.integer(bits[[1]]);key<-paste(bits[-1],collapse='::')
    if(is.na(i)||i<1||i>length(p$scales$scales)||!nzchar(key))stop('Unknown ggplot scale parameter')
    p$scales<-clone_component(p$scales)
    p$scales$scales[[i]]<-clone_component(p$scales$scales[[i]])
    if(key=='transform') {v<-scales::as.transform(v);key<-'trans'}
    p$scales$scales[[i]][[key]]<-v;return(p)
  }
  if(startsWith(prop,'coord::')) {
    key<-sub('^coord::','',prop)
    p$coordinates<-clone_component(p$coordinates)
    if(identical(class(p$coordinates)[1],'CoordCartesian')&&key%in%c('xlim','ylim'))p$coordinates$limits[[if(key=='xlim')'x'else'y']]<-v
    else p$coordinates[[key]]<-v
    return(p)
  }
  if(startsWith(prop,'facet::')) {key<-sub('^facet::','',prop);p$facet<-clone_component(p$facet);p$facet$params[[key]]<-v;return(p)}
  if(startsWith(prop,'guides::')) {
    bits<-strsplit(sub('^guides::','',prop),'::',fixed=TRUE)[[1]]
    if(length(bits)<2)stop('Invalid guide parameter path')
    aesthetic<-bits[[1]];key<-paste(bits[-1],collapse='::')
    p$guides<-clone_component(p$guides)
    if(is.null(p$guides$guides[[aesthetic]]))p$guides$guides[[aesthetic]]<-default_guide(p,aesthetic)
    else p$guides$guides[[aesthetic]]<-clone_component(p$guides$guides[[aesthetic]])
    p$guides$guides[[aesthetic]]$params[[key]]<-v;return(p)
  }
  if(startsWith(prop,'mapping::')) {
    bits<-strsplit(sub('^mapping::','',prop),'::',fixed=TRUE)[[1]]
    if(length(bits)!=2)stop('Invalid aesthetic mapping path')
    target<-bits[[1]];aesthetic<-bits[[2]];expr<-rlang::parse_expr(v)
    if(target=='plot') {old<-p$mapping[[aesthetic]];p$mapping[[aesthetic]]<-rlang::new_quosure(expr,if(rlang::is_quosure(old))rlang::quo_get_env(old) else rlang::global_env())}
    else {i<-as.integer(sub('layer-','',target));p$layers[[i]]<-clone_component(p$layers[[i]]);old<-p$layers[[i]]$mapping[[aesthetic]];p$layers[[i]]$mapping[[aesthetic]]<-rlang::new_quosure(expr,if(rlang::is_quosure(old))rlang::quo_get_env(old) else rlang::global_env())}
    return(p)
  }
  tick_match<-regexec('^axis-([bl])[.]tick-label-([0-9]+)$',id)
  tick_parts<-regmatches(id,tick_match)[[1]]
  if(length(tick_parts)==3L&&prop=='text') {
    axis<-if(tick_parts[[2]]=='b')'x' else 'y'
    return(replace_tick_label(p,axis,as.integer(tick_parts[[3]]),v))
  }
  axis<-if(id=='axis-b')'x' else if(id=='axis-l')'y' else NULL
  if(startsWith(prop,'geom::')) {
    key<-sub('^geom::','',prop);i<-as.integer(sub('layer-','',id))
    p$layers[[i]]<-clone_component(p$layers[[i]])
    if(key=='orientation'&&identical(v,'auto'))v<-NA
    p$layers[[i]]$geom_params[[key]]<-v;return(p)
  }
  if(startsWith(prop,'aes::')) {key<-sub('^aes::','',prop);i<-as.integer(sub('layer-','',id));p$layers[[i]]<-clone_component(p$layers[[i]]);p$layers[[i]]$aes_params[[key]]<-v;return(p)}
  if(startsWith(prop,'position::')) {key<-sub('^position::','',prop);i<-as.integer(sub('layer-','',id));p$layers[[i]]<-clone_component(p$layers[[i]]);p$layers[[i]]$position[[key]]<-v;return(p)}
  if(startsWith(prop,'theme::')) {
    bits<-strsplit(sub('^theme::','',prop),'::',fixed=TRUE)[[1]]
    if(length(bits)<2)stop('Invalid theme property')
    name<-bits[[1]];key<-paste(bits[-1],collapse='::')
    return(replace_theme_component(name,key,if(key=='element')expression_value(v,env) else v,whole=key=='element'))
  }
  if(id=='figure'&&prop=='r_theme') {
    spec<-jsonlite::fromJSON(v,simplifyVector=TRUE)
    if(!is.list(spec)||(!length(spec)&&v!='{}')||(length(spec)&&is.null(names(spec))))stop('Use a named JSON object for theme parameters')
    convert<-function(x) {
      if(!is.list(x)||is.null(x$type))return(x)
      type<-x$type;x$type<-NULL
      constructors<-list(element_text=element_text,element_line=element_line,element_rect=element_rect,element_blank=element_blank,unit=grid::unit,margin=ggplot2::margin)
      if(!type %in% names(constructors))stop('Unsupported theme value type')
      do.call(constructors[[type]],x)
    }
    return(p+do.call(theme,lapply(spec,convert)))
  }
  if(!is.null(axis)&&prop %in% c('xlim','ylim'))id<-'axes_0'
  if(id=='axes_0'&&prop %in% c('xscale','yscale')) {
    ax<-substr(prop,1,1);sc<-p$scales$get_scales(ax)
    if(is.null(sc)){p<-p+do.call(get(paste0('scale_',ax,'_continuous'),asNamespace('ggplot2')),list());sc<-p$scales$get_scales(ax)}
    if(sc$is_discrete())stop('A categorical axis cannot use a numeric transformation')
    sc$trans<-scales::as.transform(switch(v,linear='identity',log='log10',v));return(p)
  }
  if(id=='axes_0'&&prop %in% c('xlim','ylim')) {
    if(length(v)!=2||unlist(v)[1]>=unlist(v)[2])stop('Axis minimum must be smaller than maximum')
    ax<-substr(prop,1,1);v<-unlist(v)
    # Zoom via coord, preserving observations; explicit scale limits must not cap new ticks.
    sc<-p$scales$get_scales(ax)
    if(!is.null(sc)&&!sc$is_discrete())sc$limits<-NULL
    p$coordinates$limits[[ax]]<-v;return(p)
  }
  if(!is.null(axis)&&prop %in% c('major_mode','major_step','major_values','format','tick_labels')) {
    sc<-p$scales$get_scales(axis)
    if(is.null(sc)) {
      pp<-ggplot_build(p)$layout$panel_params[[1]][[axis]]
      scale_type<-if(pp$is_discrete())'discrete' else 'continuous'
      p<-p+do.call(get(paste0('scale_',axis,'_',scale_type),asNamespace('ggplot2')),list());sc<-p$scales$get_scales(axis)
    }
    if(prop=='major_mode') {
      if(v=='auto')sc$breaks<-waiver()
      else {
        br<-ggplot_build(p)$layout$panel_params[[1]][[axis]]$breaks;br<-br[is.finite(br)]
        if(v=='fixed')sc$breaks<-br
        else {s<-if(length(br)>1)diff(br)[1] else 1;sc$breaks<-local({step<-s;function(limits){if(diff(range(limits))/step>1000)stop('Too many ticks');seq(ceiling(min(limits)/step)*step,floor(max(limits)/step)*step,by=step)}})}
      }
    } else if(prop=='major_step') {
      if(v<=0)sc$breaks<-waiver() else {
        step<-v
        sc$breaks<-local({s<-step;function(limits){n<-diff(range(limits))/s;if(n>1000)stop('Tick interval would generate more than 1000 ticks');seq(ceiling(min(limits)/s)*s,floor(max(limits)/s)*s,by=s)}})
      }
    } else if(prop=='major_values')sc$breaks<-unlist(v)
    else if(prop=='tick_labels') {
      labs<-strsplit(v,'\n',fixed=TRUE)[[1]]
      sc$labels<-labs
    } else sc$labels<-switch(v,auto=waiver(),integer=scales::label_number(accuracy=1),decimal=scales::label_number(accuracy=.1),scientific=scales::label_scientific(),percent=scales::label_percent())
    return(p)
  }
  if(!is.null(axis)&&prop %in% c('length','width','direction')) {
    if(prop=='width')return(set_theme(paste0('axis.ticks.',axis),element_line(linewidth=v)))
    name<-paste0('axis.ticks.length.',axis)
    if(prop=='length')return(set_theme(name,unit(v,'pt')))
    old<-ggplot2::calc_element(name,theme_get()+p$theme)
    len<-if(is.null(old))2.75 else abs(convertUnit(old,'pt',valueOnly=TRUE))
    return(set_theme(name,unit(if(v=='in')-len else len,'pt')))
  }
  if(id=='axes_0'&&prop %in% c('grid_x','grid_y','grid_color','grid_linewidth','grid_linestyle','spine_color','spine_linewidth','facecolor')) {
    if(prop %in% c('grid_x','grid_y'))return(set_theme(paste0('panel.grid.major.',substr(prop,6,6)),if(v)element_line() else element_blank()))
    if(prop=='facecolor')return(set_theme('panel.background',element_rect(fill=v,colour=NA)))
    if(startsWith(prop,'spine_'))return(set_theme('panel.border',if(prop=='spine_color')element_rect(colour=v,fill=NA) else element_rect(linewidth=v,fill=NA)))
    return(set_theme('panel.grid.major',switch(prop,grid_color=element_line(colour=v),grid_linewidth=element_line(linewidth=v),grid_linestyle=element_line(linetype=v))))
  }
  if(startsWith(id,'layer-')&&prop=='r_position_params') {
    i<-as.integer(sub('layer-','',id));value<-jsonlite::fromJSON(v)
    allowed<-c('width','height','jitter.width','jitter.height','dodge.width','reverse','vjust','preserve','seed','padding','orientation')
    if(!is.list(value)||is.null(names(value))||any(!names(value)%in%allowed))stop('Use supported position parameters as a JSON object')
    for(n in names(value))p$layers[[i]]$position[[n]]<-value[[n]]
    return(p)
  }
  if(startsWith(id,'layer-')&&prop %in% c('marker','markeredgewidth','capsize','fontfamily','fontweight','hjust','vjust','r_geom_params','r_aes_params')) {
    i<-as.integer(sub('layer-','',id));l<-p$layers[[i]]
    if(prop %in% c('r_geom_params','r_aes_params')) {
      value<-jsonlite::fromJSON(v,simplifyVector=TRUE)
      if(!is.list(value)||is.null(names(value))||anyDuplicated(names(value)))stop('Use a named JSON object')
      if(prop=='r_geom_params') {
        allowed<-unique(c(l$geom$parameters(TRUE),names(l$geom_params)))
        if(any(!names(value)%in%allowed))stop('Unknown geometry parameter')
        for(n in names(value))l$geom_params[[n]]<-value[[n]]
      } else {
        allowed<-intersect(l$geom$aesthetics(),c('colour','color','fill','alpha','size','shape','stroke','linewidth','linetype','family','fontface','angle','hjust','vjust','label'))
        if(any(!names(value)%in%allowed))stop('Only visual aesthetics are editable here')
        for(n in names(value))l$aes_params[[n]]<-value[[n]]
      }
    } else if(prop=='capsize')l$geom_params$width<-v
    else {
      key<-switch(prop,marker='shape',markeredgewidth='stroke',fontfamily='family',fontweight='fontface',prop)
      if(prop=='marker')v<-unname(point_shapes[[v]])
      l$aes_params[[key]]<-v
      if(prop=='marker'&&v%in%21:25&&inherits(l$geom,'GeomPoint')) {
        has_fill_mapping<-!is.null(l$mapping$fill)||(isTRUE(l$inherit.aes)&&!is.null(p$mapping$fill))
        missing_fill<-is.null(l$aes_params$fill)||
          (length(l$aes_params$fill)==1L&&(is.na(l$aes_params$fill)||identical(l$aes_params$fill,'')))
        if(!has_fill_mapping&&missing_fill&&!preserve_empty_fill) {
          has_colour_mapping<-!is.null(l$mapping$colour)||(isTRUE(l$inherit.aes)&&!is.null(p$mapping$colour))
          if(has_colour_mapping) {
            l$aes_params$fill<-NULL
            l$mapping$fill<-rlang::new_quosure(rlang::expr(ggplot2::after_scale(colour)),env=rlang::global_env())
          }
          else l$aes_params$fill<-l$aes_params$colour %||% 'black'
        }
      }
    }
    return(p)
  }
  if(startsWith(id,'guide-box')&&prop %in% c('title_fontsize','frameon','edgecolor','facecolor','frame_linewidth','labelspacing','handlelength','handleheight')) {
    if(prop=='title_fontsize')return(p+theme(legend.title=element_text(size=v)))
    if(prop=='frameon')return(p+theme(legend.background=if(v)element_rect() else element_blank()))
    if(prop=='edgecolor')return(p+theme(legend.background=element_rect(colour=v)))
    if(prop=='facecolor')return(p+theme(legend.background=element_rect(fill=v)))
    if(prop=='frame_linewidth')return(p+theme(legend.background=element_rect(linewidth=v)))
    name<-switch(prop,labelspacing='legend.key.spacing.y',handlelength='legend.key.width',handleheight='legend.key.height')
    return(set_theme(name,unit(v,'mm')))
  }
  if(startsWith(id,'guide-box')&&prop %in% c('title','fontfamily','color','ncol','legend_position')) {
    if(prop=='title')return(p+labs(fill=v,colour=v,shape=v,size=v))
    if(prop=='fontfamily')return(p+theme(legend.text=element_text(family=v),legend.title=element_text(family=v)))
    if(prop=='color')return(p+theme(legend.text=element_text(colour=v),legend.title=element_text(colour=v)))
    if(prop=='legend_position')return(p+theme(legend.position=v))
    return(p+guides(fill=guide_legend(ncol=as.integer(v)),colour=guide_legend(ncol=as.integer(v)),shape=guide_legend(ncol=as.integer(v))))
  }
  if(id=='figure'&&prop=='legend_position') {
    if(v!='none') {
      for(i in seq_along(p$layers))p$layers[[i]]$show.legend<-TRUE
      p<-p+guides(fill=guide_legend(),colour=guide_legend(),shape=guide_legend())
    }
    return(p+theme(legend.position=v))
  }
  if(id=='figure'&&prop %in% c('title','subtitle','caption'))return(p+do.call(labs,setNames(list(v),prop)))
  NULL
}
# Group children own only per-series appearance. Keep all other R capabilities
# on the parent layer so mappings, stats, geometry and position remain editable.
point_group_parent_fields <- function(fields) {
  group_style<-c('color','facecolor','markersize','marker','markeredgewidth','alpha')
  Filter(function(f)!f$prop %in% group_style,fields)
}
errorbar_group_parent_fields <- function(fields) {
  group_style<-c('color','alpha','linewidth','capsize','linestyle')
  Filter(function(f)!f$prop %in% group_style,fields)
}
text_group_parent_fields <- function(fields) {
  group_style<-c('color','alpha','text','fontsize','rotation','fontfamily','fontweight','hjust','vjust')
  Filter(function(f)!f$prop %in% group_style,fields)
}
apply_point_groups <- function(built,patches) {
  original<-built$data
  for(a in patches)if(startsWith(a$gid,'point-group-')) {
    bits<-strsplit(sub('point-group-','',a$gid),'-',fixed=TRUE)[[1]]
    i<-as.integer(bits[1]);group<-as.integer(bits[2]);d<-built$data[[i]];rows<-which(d$group==group)
    if(!length(rows))stop('Point group no longer exists')
    key<-switch(a$prop,color='colour',facecolor='fill',markersize='size',markeredgewidth='stroke',marker='shape',alpha='alpha',visible='alpha',stop('Unsupported point-group property'))
    value<-a$value
    if(a$prop=='marker')value<-unname(point_shapes[[value]])
    if(a$prop=='visible') {if(isTRUE(value))next;value<-0}
    if(a$prop=='marker'&&value%in%21:25) {
      explicit_fill<-any(vapply(patches,function(change)identical(change$gid,a$gid)&&identical(change$prop,'facecolor'),logical(1)))
      if(!explicit_fill) {
        if(!'fill'%in%names(d))d$fill<-NA_character_
        # ggplot build output is normally character here, but a factor-valued
        # fill column cannot accept a new hex colour: R silently turns it NA.
        # Convert before the row-wise assignment so switching to pch 21:25
        # always seeds the interior from the existing per-point colour.
        d$fill<-as.character(d$fill)
        missing_fill<-is.na(d$fill[rows])|d$fill[rows]==''|d$fill[rows]=='NA'
        if(any(missing_fill)) {
          colour<-as.character(d$colour[rows][missing_fill]);colour[is.na(colour)|colour=='']<-'#333333'
          d$fill[rows[missing_fill]]<-colour
        }
      }
    }
    d[[key]][rows]<-value;built$data[[i]]<-d
    # Update only point legend glyphs; the bar legend using the same levels stays intact.
    point_layers<-which(vapply(built$plot$layers,function(l)inherits(l$geom,'GeomPoint'),logical(1)))
    if(length(point_layers)==1)for(guide in names(built$plot$guides$params)) {
      params<-built$plot$guides$params[[guide]]
      for(decor in names(params$decor))if(startsWith(decor,'geom_point')) {
        glyphs<-params$decor[[decor]]$data
        for(aes in intersect(c('colour','fill'),as.character(params$aesthetic))) {
          old<-unique(original[[i]][[aes]][rows]);index<-which(params$key[[aes]] %in% old)
          if(length(old)==1&&length(index)==1&&nrow(glyphs)==nrow(params$key)) {
            glyphs[[key]][index]<-value
            if(a$prop=='marker'&&value%in%21:25&&!explicit_fill&&
               (is.na(glyphs$fill[index])||glyphs$fill[index]==''))glyphs$fill[index]<-glyphs$colour[index]
          }
        }
        params$decor[[decor]]$data<-glyphs
      }
      built$plot$guides$params[[guide]]<-params
    }
  }
  built
}
apply_errorbar_groups <- function(built,patches) {
  for(a in patches)if(startsWith(a$gid,'errorbar-group-')) {
    bits<-strsplit(sub('errorbar-group-','',a$gid),'-',fixed=TRUE)[[1]]
    i<-as.integer(bits[1]);group<-as.integer(bits[2]);d<-built$data[[i]];rows<-which(d$group==group)
    if(!length(rows))stop('Error-bar group no longer exists')
    key<-switch(a$prop,color='colour',capsize='width',linewidth='linewidth',linestyle='linetype',alpha='alpha',visible='alpha',stop('Unsupported error-bar group property'))
    value<-a$value
    if(a$prop=='linestyle')value<-switch(value,solid=1,dashed=2,dotted=3,dotdash=4,value)
    if(a$prop=='visible') {if(isTRUE(value))next;value<-0}
    d[[key]][rows]<-value;built$data[[i]]<-d
  }
  built
}
apply_text_groups <- function(built,patches) {
  for(a in patches)if(startsWith(a$gid,'text-group-')) {
    bits<-strsplit(sub('text-group-','',a$gid),'-',fixed=TRUE)[[1]]
    i<-as.integer(bits[1]);row<-as.integer(bits[2]);d<-built$data[[i]]
    if(is.na(row)||row<1||row>nrow(d))stop('Text object no longer exists')
    key<-switch(a$prop,text='label',color='colour',fontsize='size',rotation='angle',fontfamily='family',fontweight='fontface',hjust='hjust',vjust='vjust',alpha='alpha',visible='alpha',stop('Unsupported text object property'))
    value<-a$value
    if(a$prop=='fontsize')value<-value/(72.27/25.4)
    if(a$prop=='fontweight')value<-switch(value,plain=1,bold=2,italic=3,bold.italic=4,value)
    if(a$prop=='visible') {if(isTRUE(value))next;value<-0}
    d[[key]][row]<-value;built$data[[i]]<-d
  }
  built
}
stable_grob <- function(x) {
  if(is.environment(x)||is.function(x))return(NULL)
  if(is.list(x)) {
    attrs<-attributes(x)
    if(!is.null(attrs$names))attrs$names<-gsub('[.][0-9]+$','',attrs$names)
    x<-lapply(unclass(x),stable_grob);attributes(x)<-attrs
    if('name'%in%names(x))x$name<-NULL
    if('childrenOrder'%in%names(x))x$childrenOrder<-gsub('[.][0-9]+','',x$childrenOrder)
  }
  x
}
