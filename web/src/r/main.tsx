// R transport entry; interactions and editing widgets are the upstream implementation.
import {useState,useEffect,useRef} from 'react'
import {createRoot} from 'react-dom/client'
import {useTranslation} from 'react-i18next'
import {CanvasStage} from '@/canvas/CanvasStage'
import {ElementInspector} from '@/components/inspector/ElementInspector'
import {ElementTree} from '@/components/left/ElementTree'
import {McpProviders} from '@/mcp/McpProviders'
import {ErrorBoundary} from '@/components/ErrorBoundary'
import {seedEmbeddedSession} from '@/embedded/session'
import {setEngineTransport} from '@/lib/engineTransport'
import type {EngineRenderResponse} from '@/lib/api'
import {useEngineSync} from '@/hooks/useEngineSync'
import {useKeyboard} from '@/hooks/useKeyboard'
import {runUndoRedo} from '@/hooks/useKeyboard'
import {useDocumentStore} from '@/store/documentStore'
import {usePanelRender} from '@/store/renderStore'
import {useUiStore} from '@/store/uiStore'
import type {PanelObject} from '@/types/document'
import {formatMessage,literal,nsMsg,type UiMessage,initI18n} from '@/i18n'
import {PRODUCT_NAME} from '@/lib/brand'
import {restoreRSession} from './sessionRestore'
import {fetchProjectJson,ProjectNetworkError} from './projectApi'
import {Button} from '@/components/ui/Button'
import {SearchInput} from '@/components/ui/SearchInput'
import {Select} from '@/components/ui/Select'
import {Details,Summary} from '@/components/ui/Details'
import '@/index.css'
declare global {interface Window {pywebview?:{api:{pick_file:()=>Promise<string|null>}}}}
let token=''
let sessionId=''
const sessionUrl=(url:string)=>url+'?session_id='+encodeURIComponent(sessionId)
async function post(endpoint:string,body:unknown,timeoutMs=30000){const r=await fetch('/r-api/'+endpoint,{method:'POST',headers:{'Content-Type':'application/json','x-studio-token':token},body:JSON.stringify({...body as object,session_id:sessionId}),signal:AbortSignal.timeout(timeoutMs)});const data=await r.json();if(!r.ok)throw Error(data.error);return data}
setEngineTransport({render:async(_id,patches,opts)=>{
  const r=await fetch('/r-api/apply',{method:'POST',headers:{'Content-Type':'application/json','x-studio-token':token},body:JSON.stringify({patches,session_id:sessionId}),signal:opts?.signal});
  const data=await r.json();if(!r.ok)throw Error(data.error);return data as EngineRenderResponse
},panelSrc:()=>null,previewPngUrl:async()=>{throw Error('R adapter uses SVG preview')}})
function Editor({panelId,onClose}:{panelId:string,onClose:(savedPath?:string)=>void}){
  const {t}=useTranslation('workspace')
  useEngineSync();useKeyboard()
  const past=useDocumentStore(s=>s.past.length),future=useDocumentStore(s=>s.future.length)
  const panel=useDocumentStore(s=>s.doc.objects.find(o=>o.id===panelId)) as PanelObject
  const rendered=usePanelRender(panel)
  const pending=rendered?.status!=='ready'||rendered.lastPatches!==JSON.stringify(panel.overrides)
  const [notice,setNotice]=useState<UiMessage|null>(null),[code,setCode]=useState(''),[savedKey,setSavedKey]=useState(''),[projectKey,setProjectKey]=useState<string|null>(null),[closing,setClosing]=useState(false)
  return <div className="flex h-full flex-col bg-bg text-ink">
    <header className="flex shrink-0 items-center gap-3 border-b border-border bg-surface px-3 py-2">
      <strong>{PRODUCT_NAME}{t('rStudio.productSuffix')}</strong><button onClick={()=>setClosing(true)}>{t('rStudio.closeOpenOther')}</button>
      <button disabled={!past} onClick={()=>runUndoRedo(false)}>{t('rStudio.undo')}</button><button disabled={!future} onClick={()=>runUndoRedo(true)}>{t('rStudio.redo')}</button>
      <span className="flex-1"/>
      <button disabled={pending} onClick={async()=>{try{const r=await post('save',{patches:panel.overrides});setProjectKey(JSON.stringify(panel.overrides));setNotice(nsMsg('workspace','rStudio.projectSaved',{path:r.path}))}catch(e){setNotice(literal(String(e)))}}}>{t('rStudio.saveProject')}</button>
      {projectKey===JSON.stringify(panel.overrides)&&<a href={sessionUrl('/download/project.tavotto-r.json')}>{t('rStudio.downloadProject')}</a>}
      <button disabled={pending} onClick={async()=>{try{await post('export',{patches:panel.overrides});setCode(await(await fetch(sessionUrl('/r-api/code'))).text());setSavedKey(JSON.stringify(panel.overrides))}catch(e){setNotice(literal(String(e)))}}}>{t('rStudio.viewRCode')}</button>
      <button disabled={pending} onClick={async()=>{try{const r=await post('export',{patches:panel.overrides});setProjectKey(JSON.stringify(panel.overrides));setNotice(nsMsg('workspace','rStudio.savedTo',{path:r.output}));setSavedKey(JSON.stringify(panel.overrides))}catch(e){setNotice(literal(String(e)))}}}>{t('rStudio.saveAndExport')}</button>
    </header>
    {closing&&<div role="dialog" aria-label={t('rStudio.closeProject')} className="absolute inset-0 z-50 flex items-center justify-center bg-bg/80"><div className="rounded border border-border bg-surface p-6 shadow-pop"><p>{t('rStudio.closeConfirm')}</p><div className="mt-4 flex gap-4"><button onClick={()=>setClosing(false)}>{t('rStudio.returnToEdit')}</button><button onClick={async()=>{try{const saved=await post('save',{patches:panel.overrides});await post('close',{});sessionStorage.removeItem('tavotto-r-session');onClose(saved.path)}catch(e){setNotice(literal(String(e)));setClosing(false)}}}>{t('rStudio.saveAndClose')}</button><button onClick={async()=>{await post('close',{});sessionStorage.removeItem('tavotto-r-session');onClose()}}>{t('rStudio.closeWithoutSaving')}</button></div></div></div>}
    <div className="flex min-h-0 flex-1"><aside className="w-[200px] shrink-0 overflow-auto border-r border-border bg-surface"><ElementTree/></aside><CanvasStage/><aside className="w-[300px] shrink-0 overflow-auto border-l border-border bg-surface"><ElementInspector panel={panel}/></aside></div>
    {code&&<div className="absolute inset-x-8 bottom-8 z-50 max-h-[50vh] overflow-auto rounded border border-border bg-surface p-4 shadow-pop"><button onClick={()=>setCode('')}>{t('rStudio.closeCode')}</button><a className="ml-4" href={sessionUrl("/download/figure-edited.R")}>{t('rStudio.downloadRFile')}</a><pre className="select-text text-xs">{code}</pre></div>}
    <footer className="shrink-0 border-t border-border px-3 py-1 text-xs">{rendered?.status==='error'?t('rStudio.renderFailed',{error:rendered.error}):pending?t('rStudio.updating'):rendered?.warnings?.length?rendered.warnings.join('；'):formatMessage(notice)||t('rStudio.openHint')} {savedKey===JSON.stringify(panel.overrides)&&!pending&&<><a href={sessionUrl("/download/figure.pdf")}>{t('rStudio.pdf')}</a> · <a href={sessionUrl("/download/figure.svg")}>{t('rStudio.svg')}</a> · <a href={sessionUrl("/download/figure.png")}>{t('rStudio.png600')}</a></>}</footer>
  </div>
}
type ProjectSummary={id:string;name:string;scriptCount:number;figureCount:number}
type ProjectFile={relativePath:string;name:string;kind:'script'|'project'|'figure';modifiedAt:string|null;openable?:boolean;reason?:'single'|'project'|'cached'|'multi'|'batch'|'diagnostic'|'helper'|'unknown'|'render-failed'}
function App(){
  const {t}=useTranslation('workspace')
  const [script,setScript]=useState(''),[object,setObject]=useState('tavotto_plot'),[panel,setPanel]=useState(''),[error,setError]=useState(''),[busy,setBusy]=useState(false),[native,setNative]=useState(!!window.pywebview)
  const [projects,setProjects]=useState<ProjectSummary[]>([]),[selectedProject,setSelectedProject]=useState(''),[files,setFiles]=useState<ProjectFile[]>([]),[filesProject,setFilesProject]=useState(''),[selectedFile,setSelectedFile]=useState(''),[search,setSearch]=useState(''),[filesBusy,setFilesBusy]=useState(false),[projectsBusy,setProjectsBusy]=useState(true),[fileError,setFileError]=useState('')
  const uploadInput=useRef<HTMLInputElement|null>(null)
  function adopt(result: any){sessionId=result.session_id;sessionStorage.setItem('tavotto-r-session',sessionId);const {panelId}=seedEmbeddedSession({stem:'R-figure',project:result.script,script:result.script,manifest:result.manifest,svg:result.svg,renderRevision:result.rev,overrides:result.patches},nsMsg('workspace','rStudio.openRFigure'));useUiStore.getState().setSelectedGid(null);setPanel(panelId)}
  async function readProjects(){
    setProjectsBusy(true);setFileError('')
    try{
      const data=await fetchProjectJson<{projects?:ProjectSummary[]}>('/r-api/projects')
      const next=(data.projects||[]) as ProjectSummary[]
      setProjects(next)
      setSelectedProject(current=>next.some(project=>project.id===current)?current:next[0]?.id||'')
      return next
    }catch(e){setFileError(e instanceof ProjectNetworkError?t('rStudio.projectNetworkFailed'):String(e));return []}finally{setProjectsBusy(false)}
  }
  async function readProjectScripts(id:string){
    if(!id){setFiles([]);return}
    setFilesBusy(true);setFileError('')
    try{
      const data=await fetchProjectJson<{figures?:ProjectFile[];scripts?:ProjectFile[]}>('/r-api/projects/'+encodeURIComponent(id)+'/scripts')
      const items=[...(data.figures||[]),...(data.scripts||[])] as ProjectFile[]
      setFiles(items)
      setFilesProject(id)
      setSelectedFile(current=>items.some(file=>file.relativePath===current)?current:'')
    }catch(e){setFileError(e instanceof ProjectNetworkError?t('rStudio.projectNetworkFailed'):String(e))}finally{setFilesBusy(false)}
  }
  useEffect(()=>{void(async()=>{try{
    const cfg=await(await fetch('/r-api/config')).json();token=cfg.token
    try{const state=await restoreRSession(sessionStorage.getItem('tavotto-r-session'));if(state)adopt(state)}catch(e){setError(String(e))}
    await readProjects()
  }catch(e){setError(String(e));setProjectsBusy(false)}})()},[])
  useEffect(()=>{setSelectedFile('');if(selectedProject)void readProjectScripts(selectedProject)},[selectedProject])
  useEffect(()=>{const ready=()=>setNative(true);window.addEventListener('pywebviewready',ready);return()=>window.removeEventListener('pywebviewready',ready)},[])
  if(panel)return <Editor panelId={panel} onClose={(savedPath)=>{setPanel('');if(savedPath)setScript(savedPath)}}/>
  const currentFiles=filesProject===selectedProject?files:[]
  const matchingFiles=currentFiles.filter(file=>(file.name+' '+file.relativePath).toLowerCase().includes(search.trim().toLowerCase()))
  const matchingFigures=matchingFiles.filter(file=>file.kind==='figure')
  const matchingScripts=matchingFiles.filter(file=>file.kind!=='figure')
  const selectedEntry=currentFiles.find(file=>file.relativePath===selectedFile)
  function projectFileRow(file:ProjectFile){
    const label=file.kind==='figure'?t('rStudio.projectFileFigureName',{name:file.name}):file.kind==='project'?t('rStudio.projectFileProjectName',{name:file.name}):file.name
    const reason=file.kind==='script'&&!file.openable?t(`rStudio.projectScriptReason.${file.reason||'unknown'}`):file.kind==='figure'&&!file.openable?t('rStudio.projectFigureUnavailable'):''
    return <Button key={file.relativePath} variant="ghost" active={selectedFile===file.relativePath} disabled={busy} onClick={()=>{setSelectedFile(file.relativePath);setError('')}} className="h-auto min-h-12 w-full justify-start rounded-none border-b border-border px-4 py-2.5 text-left whitespace-normal last:border-b-0">
      <span className="flex min-w-0 flex-col items-start"><span className="text-sm font-medium">{label}</span>{file.relativePath!==file.name&&<span className="mt-0.5 break-all text-xs text-ink-3">{file.relativePath}</span>}{reason&&<span className="mt-1 text-xs text-ink-3">{reason}</span>}</span>
    </Button>
  }
  async function openProjectFile(file:ProjectFile){
    setBusy(true);setError('')
    try{adopt(await post('open-selected',{projectId:selectedProject,relativePath:file.relativePath,object}))}
    catch(e){setError(String(e));if(file.kind==='figure')setFiles(current=>current.map(item=>item.relativePath===file.relativePath?{...item,openable:false,reason:'render-failed'}:item))}finally{setBusy(false)}
  }
  async function openPath(){
    if(!script.trim())return
    setBusy(true);setError('')
    try{
      const result=script.trim().toLowerCase().endsWith('.tavotto-r.json')?await post('reopen',{path:script.trim()}):await post('open',{script:script.trim(),object})
      adopt(result)
    }catch(e){setError(String(e))}finally{setBusy(false)}
  }
  async function chooseNativeFile(){
    setBusy(true);setError('')
    try{
      const chosen=await window.pywebview?.api.pick_file()
      if(!chosen)return
      setScript(chosen)
      const result=chosen.toLowerCase().endsWith('.tavotto-r.json')?await post('reopen',{path:chosen},120000):await post('open',{script:chosen,object},120000)
      adopt(result)
    }catch(e){setError(String(e))}finally{setBusy(false)}
  }
  function chooseAndOpenFile(){
    if(native){void chooseNativeFile();return}
    uploadInput.current?.click()
  }
  async function openUploadedFile(file:File|null){
    if(!file)return
    setBusy(true);setError('')
    try{adopt(await post('open-upload',{filename:file.name,content:await file.text(),object},120000))}
    catch(e){setError(String(e))}finally{setBusy(false)}
  }
  return <div className="min-h-full overflow-auto bg-bg px-5 py-10 text-ink sm:px-8">
    <main className="mx-auto w-full max-w-4xl space-y-5">
      <header className="space-y-1"><h1 className="text-xl font-medium">{PRODUCT_NAME}{t('rStudio.productSuffix')}</h1><p className="text-sm text-ink-2">{t('rStudio.landingDescription')}</p></header>
      <section className="flex flex-wrap items-center justify-between gap-4 rounded-md border border-border bg-surface p-5" aria-label={t('rStudio.chooseFile')}>
        <div className="min-w-0"><h2 className="text-sm font-medium">{t('rStudio.computerFileTitle')}</h2><p className="mt-1 text-xs text-ink-3">{native?t('rStudio.computerFileHintNative'):t('rStudio.computerFileHintBrowser')}</p></div>
        {!native&&<input ref={uploadInput} aria-label={t('rStudio.chooseFile')} type="file" accept=".R,.r,.tavotto-r.json" className="sr-only" onChange={e=>{const file=e.currentTarget.files?.[0]||null;e.currentTarget.value='';void openUploadedFile(file)}}/>}
        <Button variant="primary" loading={busy} loadingLabel={t('rStudio.opening')} disabled={busy} onClick={chooseAndOpenFile}>{t('rStudio.chooseFile')}</Button>
      </section>
      <section className="overflow-hidden rounded-md border border-border bg-surface" aria-label={t('rStudio.projectBrowserTitle')}>
        <div className="flex flex-wrap items-center justify-between gap-3 border-b border-border px-4 py-3">
          <div><h2 className="text-sm font-medium">{t('rStudio.projectBrowserTitle')}</h2><p className="mt-1 text-xs text-ink-3">{t('rStudio.projectBrowserHint')}</p></div>
          <div className="flex items-center gap-2">
            {projects.length>0&&<Select ariaLabel={t('rStudio.projectFolder')} value={selectedProject} onChange={setSelectedProject} className="max-w-56" options={projects.map(project=>({value:project.id,label:`${project.name} · ${t('rStudio.projectItemCounts',{scripts:project.scriptCount,figures:project.figureCount})}`}))}/>}
            <Button variant="secondary" loading={projectsBusy||filesBusy} loadingLabel={t('rStudio.projectLoading')} onClick={async()=>{const latest=await readProjects();const target=latest.some(project=>project.id===selectedProject)?selectedProject:latest[0]?.id;if(target)await readProjectScripts(target)}}>{t('rStudio.projectRefresh')}</Button>
          </div>
        </div>
        {projects.length>0&&<div className="border-b border-border p-3"><SearchInput aria-label={t('rStudio.projectScriptsSearch')} placeholder={t('rStudio.projectScriptsSearch')} value={search} onValueChange={setSearch}/></div>}
        <div className="max-h-[54vh] min-h-24 overflow-auto">
          {fileError?<p className="px-4 py-6 text-sm text-danger">{t('rStudio.projectLoadFailed',{error:fileError})}</p>
            :projectsBusy||filesBusy?<p className="px-4 py-6 text-sm text-ink-3">{t('rStudio.projectLoading')}</p>
              :projects.length===0?<p className="px-4 py-6 text-sm text-ink-3">{t('rStudio.projectNotConfigured')}</p>
                :files.length===0?<p className="px-4 py-6 text-sm text-ink-3">{t('rStudio.projectScriptsEmpty')}</p>
                :matchingFiles.length===0?<p className="px-4 py-6 text-sm text-ink-3">{t('rStudio.projectScriptsNoMatch')}</p>
                  :<>{matchingFigures.length>0&&<><p className="border-b border-border bg-bg px-4 py-2 text-xs font-medium text-ink-2">{t('rStudio.projectFiguresHeading')}</p>{matchingFigures.map(projectFileRow)}</>}{matchingScripts.length>0&&<><p className="border-b border-border bg-bg px-4 py-2 text-xs font-medium text-ink-2">{t('rStudio.projectScriptsHeading')}</p>{matchingScripts.map(projectFileRow)}</>}</>}
        </div>
        {projects.length>0&&<div className="flex flex-wrap items-center justify-between gap-3 border-t border-border px-4 py-3"><div className="min-w-0"><p className="truncate text-xs text-ink-3">{selectedFile?t('rStudio.projectScriptSelected',{path:selectedFile}):''}</p>{selectedEntry?.kind==='script'&&!selectedEntry.openable&&<p role="status" className="mt-1 text-xs text-ink-2">{t(`rStudio.projectScriptReason.${selectedEntry.reason||'unknown'}`)}</p>}{selectedEntry?.kind==='figure'&&selectedEntry.openable===false&&<p role="status" className="mt-1 text-xs text-ink-2">{t('rStudio.projectFigureUnavailable')}</p>}</div><Button variant="primary" loading={busy} loadingLabel={t('rStudio.opening')} disabled={!selectedEntry||selectedEntry.openable===false||busy} onClick={()=>{if(selectedEntry)void openProjectFile(selectedEntry)}}>{selectedEntry?.kind==='figure'?t('rStudio.openCachedFigure'):t('rStudio.importScript')}</Button></div>}
      </section>
      <Details className="rounded-md border border-border bg-surface px-4 py-3">
        <Summary className="cursor-pointer text-sm font-medium">{t('rStudio.pathOpenSection')}</Summary>
        <div className="mt-3 space-y-3"><p className="text-xs text-ink-3">{t('rStudio.pathOpenHint')}</p>
          <label className="block text-sm">{t('rStudio.scriptPathLabel')}<input aria-label={t('rStudio.scriptPathLabel')} className="mt-1 h-8 w-full rounded-sm border border-border bg-surface px-2 text-sm outline-none focus-visible:focus-ring" placeholder={t('rStudio.scriptPathPlaceholder')} value={script} onChange={e=>setScript(e.target.value)}/></label>
          <Details><Summary className="cursor-pointer text-xs text-ink-2">{t('rStudio.objectNameAdvanced')}</Summary><label className="mt-2 block text-sm"><span className="sr-only">{t('rStudio.objectNameAdvanced')}</span><input aria-label={t('rStudio.objectNameAdvanced')} className="h-8 w-full rounded-sm border border-border bg-surface px-2 text-sm outline-none focus-visible:focus-ring" value={object} onChange={e=>setObject(e.target.value)}/></label></Details>
          <Button variant="primary" loading={busy} loadingLabel={t('rStudio.opening')} disabled={!script.trim()} onClick={openPath}>{t('rStudio.openFigureProject')}</Button>
        </div>
      </Details>
      {(error||fileError)&&<p role="alert" className="text-sm text-danger">{error||t('rStudio.projectLoadFailed',{error:fileError})}</p>}
      <p className="text-xs text-ink-3">{t('rStudio.licenseNote')}</p>
    </main>
  </div>
}
initI18n()
createRoot(document.getElementById('root')!).render(<ErrorBoundary><McpProviders><App/></McpProviders></ErrorBoundary>)
