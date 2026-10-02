import { chromium } from '../web/node_modules/@playwright/test/index.mjs'
import { writeFile } from 'node:fs/promises'

const browser = await chromium.launch({ executablePath: 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe', headless: true })
const page = await browser.newPage({ ignoreHTTPSErrors: true })
page.on('requestfailed', (request) => console.log('REQUEST_FAILED', request.url(), request.failure()?.errorText))
page.on('console', (event) => { if (event.text().startsWith('R_STATUS')) console.log(event.text()) })
page.on('pageerror', (error) => console.log('PAGE_ERROR', error.message))
await page.route('http://127.0.0.1:8779/runtime-smoke', (route) => route.fulfill({ contentType: 'text/html', body: '<!DOCTYPE html><html><body></body></html>' }))
await page.goto('http://127.0.0.1:8779/runtime-smoke', { waitUntil: 'domcontentloaded' })
const result = await page.evaluate(async () => {
  const { BrowserRRuntime } = await import('/src/r/browserRuntime.ts')
  const runtime = new BrowserRRuntime()
  runtime.subscribe((status) => console.log('R_STATUS', JSON.stringify(status)))
  const encode = new TextEncoder()
  const { exampleScript } = await import('/src/r/browserExample.ts')
  const actualExample = await runtime.open({ files: [{ path: 'example.R', data: encode.encode(exampleScript) }], scriptPath: 'example.R' })
  if (actualExample.kind !== 'ready') throw Error('Actual UI example failed: ' + actualExample.kind)
  const actualExampleGeometry = actualExample.response.manifest.size_mm
  if (Math.abs(actualExampleGeometry[0] - 238.125) > 1e-8 || Math.abs(actualExampleGeometry[1] - 158.75) > 1e-8)
    throw Error('Actual example did not retain original 900 x 600 px geometry')
  const actualExamplePoints = actualExample.response.manifest.elements.filter(element => element.gid.startsWith('point-group-'))
  if (actualExamplePoints.length !== 4) throw Error('Actual example did not retain 4 semantic scatter groups')
  const editValue = (response, gid, prop) => response.manifest.elements.find(element => element.gid === gid)?.editable.find(field => field.prop === prop)?.value
  const originalExampleFill = editValue(actualExample.response, actualExamplePoints[0].gid, 'facecolor')
  const editedExample = await runtime.apply([{ gid: actualExamplePoints[0].gid, prop: 'marker', value: 's' }])
  if (editValue(editedExample, actualExamplePoints[0].gid, 'facecolor') !== originalExampleFill)
    throw Error('Changing the actual example point shape discarded its existing fill')
  const markerPlot = await runtime.open({files:[{path:'markers.R',data:encode.encode(`library(ggplot2)
    d <- data.frame(x=rep(c('A','B'),each=2),y=1:4)
    p <- ggplot(d,aes(x,y,colour=x))+geom_point(shape=19,size=3)+theme_classic()
    ggsave('markers.svg',p,width=480,height=320,units='px',dpi=96)`)}],scriptPath:'markers.R'})
  if (markerPlot.kind !== 'ready') throw Error('Marker regression fixture did not open')
  const markerGroups = markerPlot.response.manifest.elements.filter(element=>element.gid.startsWith('point-group-'))
  if (markerGroups.length !== 2) throw Error('Marker regression fixture lost independent groups')
  const markerGid = markerGroups[0].gid
  const markerColour = editValue(markerPlot.response,markerGid,'color')
  const markerChanged = await runtime.apply([{gid:markerGid,prop:'marker',value:'o'}])
  if(editValue(markerChanged,markerGid,'facecolor')!==markerColour)
    throw Error('shape19 to shape21 did not retain colour as its interior fill')
  for (const patches of [
    [{gid:markerGid,prop:'facecolor',value:'#123456'},{gid:markerGid,prop:'marker',value:'o'}],
    [{gid:markerGid,prop:'marker',value:'o'},{gid:markerGid,prop:'facecolor',value:'#123456'}],
  ]) {
    const explicit = await runtime.apply(patches)
    if (editValue(explicit,markerGid,'facecolor') !== '#123456')
      throw Error('Automatic marker fill overrode an explicit fill patch')
  }
  const script = `library(ggplot2)
  d <- read.csv('data.csv')
  p <- ggplot(d,aes(x=group,y=mean,fill=group)) + geom_col(width=.55) +
    geom_errorbar(aes(ymin=mean-se,ymax=mean+se),width=.2) +
    geom_point(aes(y=mean+.3),shape=21,size=2,colour='black') +
    labs(title='Browser R semantic editor',x='Treatment',y='Mean') + theme_classic()
  ggsave('figure-original.svg',plot=p,width=480,height=320,units='px',dpi=96)`
  const files = [{ path: 'figure.R', data: encode.encode(script) },
    { path: 'data.csv', data: encode.encode('group,mean,se\nA,2,.4\nB,4,.7\n') }]
  const opened = await runtime.open({ files, scriptPath: 'figure.R' })
  if (opened.kind !== 'ready') throw Error('Unexpected open result '+opened.kind)
  const before = opened.response.manifest
  const changed = await runtime.apply([{ gid: 'title', prop: 'text', value: 'Edited in browser' }])
  const code = await runtime.code([{ gid: 'title', prop: 'text', value: 'Edited in browser' }])
  const originalFrame = before.elements.find((element) => element.gid === 'axes_0').editable.find((field) => field.prop === 'frame_mm').value
  const resized = await runtime.apply([{ gid: 'figure', prop: 'size_mm', value: [160,100] }])
  const afterFrame = resized.manifest.elements.find((element) => element.gid === 'axes_0').editable.find((field) => field.prop === 'frame_mm').value
  if (JSON.stringify(originalFrame) !== JSON.stringify(afterFrame)) throw Error('Canvas resize changed physical frame')
  const overflowFrame = [...originalFrame]; overflowFrame[0] += 90
  const beyondPaper = await runtime.apply([{ gid: 'axes_0', prop: 'frame_mm', value: overflowFrame }])
  const surface = document.createElement('div'); surface.innerHTML = beyondPaper.svg
  document.body.appendChild(surface)
  const svg = surface.querySelector('svg'); svg.style.width = '480px'; svg.style.height = '320px'
  const paperBounds = svg.getBoundingClientRect()
  const barBounds = svg.querySelector('[id="fill-group-1-2"]').getBoundingClientRect()
  const overflowPreview = { paperRight: paperBounds.right, barRight: barBounds.right,
    visibleGeometryOutsidePaper: barBounds.right > paperBounds.right }
  surface.remove()
  if (!overflowPreview.visibleGeometryOutsidePaper) throw Error('Overscan did not retain out-of-paper bar geometry')
  await runtime.apply([{ gid: 'title', prop: 'text', value: 'Edited in browser' }])
  const exported = await runtime.export()
  const sizes = exported.files.map((file) => ({ name: file.name, size: file.bytes.length,
    signature: Array.from(file.bytes.slice(0,8)) }))
  const portable = await runtime.saveProject()
  const restored = await runtime.loadProject(portable)
  if (restored.kind !== 'ready') throw Error('Unexpected project restore '+restored.kind)
  const noSize = await runtime.open({ files: [{ path: 'no-size.R', data: encode.encode("library(ggplot2);p<-ggplot(mtcars,aes(wt,mpg))+geom_point()") }], scriptPath: 'no-size.R' })
  const fallback = await runtime.selectObject('p', [600,400])
  const multi = await runtime.open({ files: [{ path: 'multi.R', data: encode.encode(`library(ggplot2)
    execution_count <- 1L
    a <- ggplot(mtcars,aes(wt,mpg))+geom_point()
    b <- ggplot(mtcars,aes(factor(cyl),mpg))+geom_boxplot()
    ggsave('a.pdf',a,width=5,height=4);ggsave('b.pdf',b,width=6,height=3)`) }], scriptPath: 'multi.R' })
  if (multi.kind !== 'choose-object' || multi.objects.length !== 2) throw Error('Multi-plot chooser did not identify both plots')
  const picked = await runtime.selectObject('b')
  if (picked.kind !== 'ready') throw Error('Multi-plot selection failed')
  const captured = await runtime.open({ files: [{ path: 'captured.R', data: encode.encode(`library(ggplot2)
    make_plot <- function() { q <- ggplot(mtcars,aes(wt,mpg))+geom_point();ggsave('q.pdf',q,width=5,height=4) }
    make_plot()`) }], scriptPath: 'captured.R' })
  if (captured.kind !== 'ready') throw Error('ggsave-local plot was not captured')
  const capturedExport = await runtime.export()
  const corrupted = JSON.parse(portable); corrupted.files[0].base64 = btoa('changed')
  let tamperRejected = false
  try { await runtime.loadProject(JSON.stringify(corrupted)) } catch { tamperRejected = true }
  if (!tamperRejected) throw Error('Portable project accepted mismatched source hash')
  runtime.reset()
  return { actualUiExample: { size_mm: actualExampleGeometry, scatterGroups: actualExamplePoints.length, sourceUnchanged: actualExample.sourceHash.length === 64 },
    markerRegression: { existingFillRetained: originalExampleFill === editValue(editedExample, actualExamplePoints[0].gid, 'facecolor'),
      shape19To21Fill: editValue(markerChanged,markerGid,'facecolor'), originalColour: markerColour, explicitFillWinsInBothOrders: true },
    opened: { kind: opened.kind, size_mm: before.size_mm, roles: before.elements.map((element)=>element.role),
    elements: before.elements.length, sourceHash: opened.sourceHash, svgBytes: opened.response.svg.length },
    changed: { svgBytes: changed.svg.length, title: changed.manifest.elements.find((element)=>element.gid==='title')?.label },
    code: { bytes: code.length, includesNativeLabs: code.includes('labs(title = "Edited in browser")'),
      hasAbsolutePath: code.includes('/project/') }, files: sizes,
    portable: { bytes: portable.length, absolutePath: portable.includes('/project/') },
    restored: restored.response.manifest.size_mm, noSize: noSize.kind,
    fallback: fallback.kind==='ready'?fallback.response.manifest.size_mm:fallback.kind,
    geometry: { beforeFrame: originalFrame, afterFrame, resizePageMm: resized.manifest.size_mm,
      keptPhysicalFrame: JSON.stringify(originalFrame) === JSON.stringify(afterFrame), overflowPreview },
    multi: { objects: multi.objects, pickedSizeMm: picked.response.manifest.size_mm },
    captured: { object: captured.object, nativeRds: capturedExport.files.some((file)=>file.name==='figure-source.rds'),
      replayUsesRds: capturedExport.code.includes('readRDS("figure-source.rds")') }, tamperRejected,
    crossOriginIsolated: globalThis.crossOriginIsolated }
})
console.log(JSON.stringify(result, null, 2))
await writeFile(new URL('./browser-smoke-report.json', import.meta.url), JSON.stringify(result,null,2))
await browser.close()
