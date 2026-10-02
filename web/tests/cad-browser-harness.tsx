import {createRoot} from 'react-dom/client'
import {CanvasStage} from '@/canvas/CanvasStage'
import {TooltipProvider} from '@/components/ui/Tooltip'
import {literal, initI18n} from '@/i18n'
import type {Manifest, ManifestElement} from '@/lib/api'
import {setEngineTransport} from '@/lib/engineTransport'
import {useDocumentStore} from '@/store/documentStore'
import {useRenderStore} from '@/store/renderStore'
import {useUiStore} from '@/store/uiStore'
import {useSelectionStore} from '@/store/selectionStore'
import {getTransform, mmToWorld, useViewportStore} from '@/store/viewportStore'
import {seedExactRender} from '@/test/renderFixtures'
import {emptyProject, type PanelObject} from '@/types/document'
import '@/index.css'

// A isolated browser fixture uses the real CanvasStage and stores. No server
// project, user file, runtime interpreter or current user browser is involved.
globalThis.fetch = (async () => new Response('{}', {status: 200})) as typeof fetch
setEngineTransport({render: async () => {throw Error('fixture cannot render')},
  panelSrc: () => null, previewPngUrl: async () => {throw Error('fixture is SVG')}})
initI18n('zh-CN')
const p: PanelObject = {id:'fixture',type:'panel',fileId:'fixture.pdf',fileKind:'pdf',
  x:20,y:15,w:100,h:80,nativeW:100,nativeH:80,script:'fixture.R',overrides:[]}
const el=(gid:string,bbox:number[],patch:Partial<ManifestElement>={})=>({
  gid,role:'bar',label:gid,bbox,editable:[],draggable:false,canvas_selectable:true,
  r_native:true,...patch}) as unknown as ManifestElement
const manifest:Manifest={stem:'fixture',size_mm:[100,80],elements:[
  el('figure',[0,0,1,1],{role:'figure',canvas_selectable:false}),
  el('axes_0',[.1,.1,.8,.8],{role:'axes',canvas_selectable:false}),
  el('layer-1',[.1,.1,.8,.8],{canvas_selectable:false}),
  el('inside',[.1,.2,.2,.1]),el('partial',[.35,.2,.2,.1]),
  el('outside',[-.35,.65,.1,.1],{role:'text'}),
  el('errorbar',[.1,.48,.5,.01],{role:'line',geometry:{kind:'polyline',fill:false,stroke:true,
    paths:[{points:[[.1,.485],[.6,.485]],closed:false}]}}),
  el('diagonal',[.05,.1,.5,.6],{role:'line',geometry:{kind:'polyline',fill:false,stroke:true,
    paths:[{points:[[.05,.1],[.55,.7]],closed:false}]}}),
]}
const svg='<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1000 800" style="width:100%;height:100%;display:block">'+
  '<rect x="100" y="80" width="800" height="640" fill="none" stroke="black"/>'+
  '<rect x="100" y="160" width="200" height="80" fill="#4F86C6"/>'+
  '<rect x="350" y="160" width="200" height="80" fill="#D98B5F"/>'+
  '<text x="-340" y="585" font-size="32">outside</text>'+
  '<path d="M100 388H600 M50 80L550 560" fill="none" stroke="black" stroke-width="3"/></svg>'
await useDocumentStore.getState().switchDocument(emptyProject(),'cad-browser-fixture')
useDocumentStore.getState().commit(literal('fixture'),d=>{
  d.page.w=100;d.page.h=80;d.objects.push(p)
})
useDocumentStore.setState({past:[],future:[]})
useUiStore.setState({tool:'select',elementPanelId:p.id,selectedGids:[],showRulers:false})
seedExactRender(p,manifest,{svg})
useRenderStore.setState({render:async()=>{}})
createRoot(document.getElementById('root')!).render(<TooltipProvider><CanvasStage/></TooltipProvider>)
const harness={
  ready:false,
  point:(fx:number,fy:number)=>{
    const t=getTransform();return {x:t.originX+t.panX+mmToWorld(p.x+p.w*fx)*t.zoom,
      y:t.originY+t.panY+mmToWorld(p.y+p.h*fy)*t.zoom}
  },
  state:()=>({gids:useUiStore.getState().selectedGids,objects:useSelectionStore.getState().ids,
    history:useDocumentStore.getState().past.length,doc:JSON.stringify(useDocumentStore.getState().doc)}),
  clear:()=>useUiStore.getState().setSelectedGids([]),
}
Object.assign(window,{cadHarness:harness})
setTimeout(()=>{useViewportStore.getState().setView({zoom:1,panX:200,panY:120});harness.ready=true},100)
