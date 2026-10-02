import {useEffect, useRef, useState} from 'react'
import {createRoot} from 'react-dom/client'
import {CanvasStage} from '@/canvas/CanvasStage'
import {ElementInspector} from '@/components/inspector/ElementInspector'
import {ElementTree} from '@/components/left/ElementTree'
import {Button} from '@/components/ui/Button'
import {Dialog} from '@/components/ui/Dialog'
import {TextInput} from '@/components/ui/Input'
import {Select} from '@/components/ui/Select'
import {ErrorBoundary} from '@/components/ErrorBoundary'
import {McpProviders} from '@/mcp/McpProviders'
import {seedEmbeddedSession} from '@/embedded/session'
import {setEngineTransport} from '@/lib/engineTransport'
import {PRODUCT_NAME, REPO_URL, BROWSER_REPO_URL} from '@/lib/brand'
import {useEngineSync} from '@/hooks/useEngineSync'
import {runUndoRedo, useKeyboard} from '@/hooks/useKeyboard'
import {useDocumentStore} from '@/store/documentStore'
import {usePanelRender} from '@/store/renderStore'
import {useUiStore} from '@/store/uiStore'
import {useViewportStore} from '@/store/viewportStore'
import type {PanelObject, PanelOverride} from '@/types/document'
import {initI18n, literal} from '@/i18n'
import {browserRuntime, WEBR_VERSION, type BrowserOpenResult, type BrowserRuntimeStatus, type BrowserFile, type BrowserExportResult} from './browserRuntime'
import {readSelectedFiles, downloadBytes, saveLastProject, readLastProject} from './browserFiles'
import {exampleScript} from './browserExample'
import '@/index.css'

setEngineTransport({
  render: async (_id, patches, options) => {
    if (options?.signal?.aborted) throw new DOMException('Cancelled', 'AbortError')
    const result = await browserRuntime.apply(patches)
    if (options?.signal?.aborted) throw new DOMException('Cancelled', 'AbortError')
    return result
  },
  panelSrc: () => null,
  previewPngUrl: async () => {throw Error('此 R 图形使用可编辑的 SVG 预览。')},
})

type Context = {scriptPath: string; object: string}
function readableError(error: unknown) {return error instanceof Error ? error.message : String(error)}

function Editor({panelId, context, onClose}: {panelId: string; context: Context; onClose: () => void}) {
  useEngineSync(); useKeyboard()
  const panel = useDocumentStore(s => s.doc.objects.find(o => o.id === panelId)) as PanelObject
  const past = useDocumentStore(s => s.past.length), future = useDocumentStore(s => s.future.length)
  const rendered = usePanelRender(panel)
  const [notice, setNotice] = useState(''), [code, setCode] = useState(''), [codeOpen, setCodeOpen] = useState(false)
  const [exports, setExports] = useState<BrowserExportResult | null>(null), [exportsOpen, setExportsOpen] = useState(false)
  const [sourceOpen, setSourceOpen] = useState(false), [closing, setClosing] = useState(false), [leftOpen, setLeftOpen] = useState(true)
  const [savedKey, setSavedKey] = useState('')
  const patchKey = JSON.stringify(panel.overrides)
  const pending = rendered?.status !== 'ready' || rendered.lastPatches !== patchKey
  const counter = useRef(0)
  useEffect(() => {
    if (pending) return
    const sequence = ++counter.current
    const timer = setTimeout(() => {
      void browserRuntime.saveProject(panel.overrides).then(async project => {
        if (sequence !== counter.current) return
        await saveLastProject(project)
        if (sequence === counter.current) setSavedKey(patchKey)
      }).catch(error => setNotice('浏览器保存失败：' + readableError(error)))
    }, 900)
    return () => {clearTimeout(timer); ++counter.current}
  }, [patchKey, pending, panel.overrides])
  async function saveProject() {
    const project = await browserRuntime.saveProject(panel.overrides)
    downloadBytes(context.object + '.tavotto-r.json', project, 'application/json')
    try {
      await saveLastProject(project)
      setSavedKey(patchKey); setNotice('项目已下载，包含脚本、选定数据和全部修改。')
    } catch (error) {
      setSavedKey('')
      setNotice('项目已下载。浏览器存储不可用，自动恢复失败：' + readableError(error))
    }
  }
  async function generateExports() {
    try {setExports(await browserRuntime.export(panel.overrides)); setExportsOpen(true)}
    catch (error) {setNotice(readableError(error))}
  }
  return <div className="flex h-dvh flex-col bg-bg text-ink" data-testid="browser-editor">
    <header className="flex h-11 shrink-0 items-center gap-2 border-b border-border bg-surface px-3">
      <strong className="whitespace-nowrap text-sm">{PRODUCT_NAME} · R</strong>
      <Button data-testid="close-figure" onClick={() => setClosing(true)}>打开其他图</Button>
      <span className="mx-1 hidden max-w-48 truncate text-xs text-ink-2 xl:block" title={context.scriptPath}>{context.scriptPath.split('/').at(-1)} / {context.object}</span>
      <Button disabled={!past} onClick={() => runUndoRedo(false)}>撤销</Button>
      <Button disabled={!future} onClick={() => runUndoRedo(true)}>重做</Button>
      <span className="flex-1" />
      <span className="hidden text-xs text-ink-3 xl:block">{savedKey === patchKey ? '已保存在此浏览器' : '编辑中'}</span>
      <Button disabled={pending} data-testid="save-project" onClick={async () => {try {await saveProject()} catch(error) {setNotice(readableError(error))}}}>下载项目</Button>
      <Button disabled={pending} data-testid="view-code" onClick={async () => {
        try {setCode(await browserRuntime.code(panel.overrides)); setCodeOpen(true)} catch(error) {setNotice(readableError(error))}
      }}>查看 R 代码</Button>
      <Button disabled={pending} variant="primary" data-testid="export-figure" onClick={generateExports}>导出图形</Button>
    </header>
    <div className="flex min-h-0 flex-1">
      {leftOpen && <aside className="w-[220px] shrink-0 overflow-auto border-r border-border bg-surface"><ElementTree /></aside>}
      <div className="relative flex min-w-0 flex-1"><CanvasStage />
        <div className="absolute left-8 top-8 z-20 flex gap-1 rounded-md bg-surface/95 p-1 shadow-pop">
          <Button onClick={() => setLeftOpen(value => !value)}>{leftOpen ? '收起对象' : '对象列表'}</Button>
          <Button data-testid="select-page" onClick={() => useUiStore.getState().setSelectedGid('figure')}>画布</Button>
          <Button data-testid="select-frame" onClick={() => useUiStore.getState().setSelectedGid('axes_0')}>图框</Button>
          <Button onClick={() => {const page = useDocumentStore.getState().doc.page; useViewportStore.getState().fitAnimated(page.w, page.h)}}>适应视图</Button>
        </div>
      </div>
      <aside className="w-[320px] max-w-[38vw] shrink-0 overflow-auto border-l border-border bg-surface">
        <ElementInspector panel={panel} />
        <div className="border-t border-border p-3"><Button onClick={() => setSourceOpen(true)}>当前脚本与运行信息</Button><p className="mt-1 text-xs text-ink-3">几何尺寸显示 px；R 原生参数保留代码单位。</p></div>
      </aside>
    </div>
    <footer role="status" className="flex min-h-7 shrink-0 items-center gap-2 border-t border-border bg-surface px-3 text-xs text-ink-2">
      <span className="min-w-0 flex-1 truncate">{rendered?.status === 'error' ? readableError(rendered.error) : pending ? '正在更新图形…' : notice || '点选编辑 · 空白处拖框：左→右全包含，右→左相交 · Ctrl+Z 撤销'}</span>
      <a className="shrink-0 underline" href={BROWSER_REPO_URL} target="_blank" rel="noreferrer">源码 · 非官方 R 版</a>
      {notice && <Button size="icon-xs" aria-label="关闭提示" onClick={() => setNotice('')}>×</Button>}
    </footer>
    <Dialog open={codeOpen} onOpenChange={setCodeOpen} title="当前修改对应的 R 代码" width={880} description="保存和重放使用同一组修改。原始脚本随项目保留。" footer={<Button onClick={() => downloadBytes('figure-edited.R', code, 'text/plain')}>下载 R 文件</Button>}>
      <pre className="max-h-[62vh] overflow-auto whitespace-pre-wrap break-words text-xs" data-testid="r-code">{code}</pre>
    </Dialog>
    <Dialog open={exportsOpen} onOpenChange={setExportsOpen} title="导出图形" description="导出使用当前画布尺寸；画布外的图形内容会在输出页边界处裁切。">
      <div className="space-y-2">{exports?.files.map(file => <Button key={file.name} variant="secondary" className="w-full justify-between" data-testid={'download-' + file.name} onClick={() => downloadBytes(file.name, file.bytes, file.mime)}>{file.name}<span className="text-xs text-ink-3">{Math.round(file.bytes.length / 1024)} KB</span></Button>)}</div>
    </Dialog>
    <Dialog open={sourceOpen} onOpenChange={setSourceOpen} title="当前脚本与运行信息">
      <dl className="space-y-3 text-sm"><div><dt className="text-ink-3">脚本</dt><dd className="break-all">{context.scriptPath}</dd></div><div><dt className="text-ink-3">图对象</dt><dd>{context.object}</dd></div><div><dt className="text-ink-3">执行环境</dt><dd>浏览器内 R · WebR {WEBR_VERSION}</dd></div><div><dt className="text-ink-3">修改</dt><dd>{panel.overrides.length} 项；保存项目可重新打开</dd></div></dl>
    </Dialog>
    <Dialog open={closing} onOpenChange={setClosing} title="打开其他图" description="当前项目可下载后再次打开，继续修改。" footer={<><Button onClick={() => setClosing(false)}>继续编辑</Button><Button disabled={pending} onClick={async () => {await saveProject(); onClose()}}>下载项目并返回</Button><Button variant="primary" onClick={onClose}>返回导入</Button></>}><p className="text-sm text-ink-2">浏览器的自动保存只保留最近一个项目。</p></Dialog>
  </div>
}

function App() {
  const [files, setFiles] = useState<BrowserFile[]>([]), [scriptPath, setScriptPath] = useState('')
  const [panelId, setPanelId] = useState(''), [context, setContext] = useState<Context>({scriptPath: '', object: ''})
  const [status, setStatus] = useState<BrowserRuntimeStatus>(browserRuntime.status), [busy, setBusy] = useState(false), [error, setError] = useState('')
  const [objects, setObjects] = useState<string[]>([]), [chosenObject, setChosenObject] = useState(''), [needsSize, setNeedsSize] = useState(false)
  const [sizeReason, setSizeReason] = useState<'conflicting_export_sizes' | 'missing_export_size'>('missing_export_size')
  const [width, setWidth] = useState(''), [height, setHeight] = useState(''), [recent, setRecent] = useState<string | null>(null)
  const fileInput = useRef<HTMLInputElement>(null), folderInput = useRef<HTMLInputElement>(null), projectInput = useRef<HTMLInputElement>(null)
  const operation = useRef(0), projectPatches = useRef<PanelOverride[]>([])
  useEffect(() => browserRuntime.subscribe(setStatus), [])
  useEffect(() => {void readLastProject().then(saved => {if (typeof saved === 'string') setRecent(saved)}).catch(() => {})}, [])
  function adopt(result: BrowserOpenResult, sourcePath = scriptPath) {
    if (result.kind === 'choose-object') {setObjects(result.objects); setChosenObject(result.objects[0] || ''); return}
    if (result.kind === 'choose-size') {setNeedsSize(true); setChosenObject(result.object); setSizeReason(result.reason ?? 'missing_export_size'); return}
    const {panelId: id} = seedEmbeddedSession({stem: result.object, project: 'browser-project', script: sourcePath,
      manifest: result.response.manifest, svg: result.response.svg ?? null, renderRevision: result.response.rev,
      overrides: projectPatches.current}, literal('打开 R 图形'))
    useUiStore.getState().setSelectedGid('figure')
    setContext({scriptPath: sourcePath, object: result.object}); setPanelId(id); setObjects([]); setNeedsSize(false)
  }
  async function execute(action: () => Promise<BrowserOpenResult>, sourcePath = scriptPath) {
    const sequence = ++operation.current
    setBusy(true); setError('')
    try {const result = await action(); if (sequence === operation.current) adopt(result, sourcePath)}
    catch (problem) {if (sequence === operation.current) setError(readableError(problem))}
    finally {if (sequence === operation.current) setBusy(false)}
  }
  async function chooseFiles(selected: FileList | null) {
    if (!selected?.length) return
    try {
      const picked = await readSelectedFiles(selected), merged = new Map(files.map(file => [file.path, file]))
      for (const file of picked) merged.set(file.path, file)
      const next = [...merged.values()]; setFiles(next); setError(''); setObjects([]); setNeedsSize(false)
      const scripts = next.filter(file => /\.r$/i.test(file.path))
      if (!scriptPath || !next.some(file => file.path === scriptPath)) setScriptPath(scripts[0]?.path || '')
    } catch (problem) {setError(readableError(problem))}
  }
  async function loadProject(input: File | string) {
    const contents = typeof input === 'string' ? input : await input.text()
    try {
      const parsed = JSON.parse(contents) as {scriptPath?: string; patches?: PanelOverride[]}
      const sourcePath = parsed.scriptPath || 'project.R'
      projectPatches.current = parsed.patches ?? []
      await execute(() => browserRuntime.loadProject(contents), sourcePath)
    } catch (problem) {setError(readableError(problem))}
  }
  function cancel() {++operation.current; browserRuntime.reset(); setBusy(false); setError('运行已停止；所选文件仍保留，可重新打开。')}
  if (panelId) return <Editor key={panelId} panelId={panelId} context={context} onClose={() => {setPanelId(''); setError(''); void readLastProject().then(saved => setRecent(typeof saved === 'string' ? saved : null)).catch(() => {})}} />
  const scripts = files.filter(file => /\.r$/i.test(file.path))
  return <div className="min-h-dvh overflow-auto bg-bg px-5 py-10 text-ink" data-testid="browser-import">
    <main className="mx-auto w-full max-w-3xl space-y-6">
      <header><h1 className="text-xl font-medium">{PRODUCT_NAME} · R</h1><p className="mt-2 text-sm text-ink-2">打开 R 绘图脚本，在图上直接修改，再带着代码保存。</p></header>
      <section className="space-y-4 rounded-md border border-border bg-surface p-5">
        <div><h2 className="text-sm font-medium">从电脑导入</h2><p className="mt-1 text-sm text-ink-2">选择 .R 脚本和它使用的数据；也可以选择整个项目文件夹，保留相对目录。</p><p className="mt-1 text-xs text-ink-3">文件在此浏览器内处理。首次运行会下载 R 环境和所需的绘图包。</p></div>
        <input ref={fileInput} type="file" multiple className="sr-only" data-testid="input-files" onChange={event => {void chooseFiles(event.currentTarget.files); event.currentTarget.value = ''}} />
        <input ref={folderInput} type="file" multiple {...{webkitdirectory: '', directory: ''}} className="sr-only" data-testid="input-folder" onChange={event => {void chooseFiles(event.currentTarget.files); event.currentTarget.value = ''}} />
        <input ref={projectInput} type="file" accept=".tavotto-r.json,.json" className="sr-only" data-testid="input-project" onChange={event => {const file = event.currentTarget.files?.[0]; event.currentTarget.value = ''; if (file) void loadProject(file)}} />
        <div className="flex flex-wrap gap-2"><Button variant="secondary" disabled={busy} data-testid="choose-files" onClick={() => fileInput.current?.click()}>选择脚本与数据</Button><Button variant="secondary" disabled={busy} onClick={() => folderInput.current?.click()}>选择项目文件夹</Button><Button disabled={busy} onClick={() => projectInput.current?.click()}>打开已保存项目</Button></div>
        {files.length > 0 && <div className="space-y-3 border-t border-border pt-4">
          <div className="flex items-center justify-between"><span className="text-xs text-ink-2">已选 {files.length} 个文件 · {(files.reduce((sum, file) => sum + file.data.length, 0) / 1024).toFixed(0)} KB</span><Button disabled={busy} onClick={() => {setFiles([]); setScriptPath(''); setError('')}}>清空所选文件</Button></div>
          <div className="max-h-40 overflow-auto text-xs text-ink-2">{files.map(file => <div key={file.path} className="flex items-center justify-between gap-3 py-1"><span className="break-all">{file.path}</span><Button size="icon-xs" disabled={busy} aria-label={'移除 ' + file.path} onClick={() => {setFiles(current => current.filter(item => item.path !== file.path)); if (scriptPath === file.path) setScriptPath('')}}>×</Button></div>)}</div>
          <label className="flex items-center gap-3 text-sm">运行脚本<Select ariaLabel="运行脚本" value={scriptPath} onChange={setScriptPath} options={scripts.map(file => ({value: file.path, label: file.path}))} /></label>
          {scripts.length === 0 && <p className="text-sm text-danger">还没有 .R 脚本，请继续选择文件。</p>}
          <Button variant="primary" disabled={busy || !scriptPath} data-testid="open-script" onClick={() => {projectPatches.current = []; void execute(() => browserRuntime.open({files, scriptPath}))}}>打开图形</Button>
        </div>}
      </section>
      <section className="flex flex-wrap items-center justify-between gap-3 border-t border-border pt-5"><div><h2 className="text-sm font-medium">先试一下</h2><p className="mt-1 text-xs text-ink-3">四组柱形、散点和误差线；可调图框、画布、坐标轴和对象样式。</p></div><Button disabled={busy} data-testid="open-example" onClick={() => {
        const sample = [{path: 'example.R', data: new TextEncoder().encode(exampleScript)}]; setFiles(sample); setScriptPath('example.R'); projectPatches.current = []
        void execute(() => browserRuntime.open({files: sample, scriptPath: 'example.R'}), 'example.R')
      }}>打开示例图</Button></section>
      {recent && <Button disabled={busy} data-testid="resume-project" onClick={() => void loadProject(recent)}>继续此浏览器最近保存的项目</Button>}
      {busy && <div role="status" className="space-y-2 rounded-md border border-border bg-surface p-4"><p className="text-sm">{status.message || '正在准备…'}</p><p className="text-xs text-ink-3">首次准备通常比后续编辑慢。文件留在浏览器内。</p><Button onClick={cancel}>停止本次运行</Button></div>}
      {error && <div role="alert" className="space-y-2 rounded-md border border-danger/30 bg-surface p-4"><p className="whitespace-pre-wrap break-words text-sm text-danger">{error}</p><p className="text-xs text-ink-2">如果缺少数据，请补选对应文件或项目文件夹后重新打开；电脑绝对路径需要在脚本中改成所选文件的相对路径。</p></div>}
      <footer className="space-y-1 border-t border-border pt-4 text-xs text-ink-3"><p>浏览器内 R · WebR {WEBR_VERSION} · AGPL-3.0-only 非官方衍生项目</p><p>支持单个 ggplot 绘图区。多张 ggplot 可选择目标对象；复杂分面及拼图会明确提示。</p><div className="flex gap-4"><a className="underline" href={BROWSER_REPO_URL}>本版本源码</a><a className="underline" href={REPO_URL}>上游 {PRODUCT_NAME}</a><a className="underline" href="./PRIVACY.md">文件与隐私</a></div></footer>
    </main>
    <Dialog open={objects.length > 0} onOpenChange={open => {if (!open) setObjects([])}} title="选择要编辑的 ggplot 对象" description="脚本包含多张图，选择其中一张进入编辑器。" footer={<Button variant="primary" disabled={busy || !chosenObject} onClick={() => void execute(() => browserRuntime.selectObject(chosenObject))}>打开这张图</Button>}>
      <Select ariaLabel="图对象" value={chosenObject} onChange={setChosenObject} options={objects.map(name => ({value: name, label: name}))} />
    </Dialog>
    <Dialog open={needsSize} onOpenChange={setNeedsSize} title="指定输出画布尺寸" description={sizeReason === 'conflicting_export_sizes' ? '这张图在脚本中有多个不同的导出尺寸，请选择本次编辑使用的画布大小。' : '这个脚本没有声明图形导出尺寸，请为这次编辑填写画布大小。已有 R 导出尺寸会优先使用。'} footer={<Button variant="primary" disabled={busy || !Number.isFinite(Number(width)) || !Number.isFinite(Number(height)) || Number(width) <= 0 || Number(height) <= 0 || !width || !height} onClick={() => void execute(() => browserRuntime.selectObject(chosenObject, [Number(width), Number(height)]))}>创建画布</Button>}>
      <div className="grid grid-cols-2 gap-4"><label className="space-y-2 text-sm">宽度<TextInput aria-label="画布宽度" type="number" min="1" suffix="px" value={width} onChange={event => setWidth(event.target.value)} /></label><label className="space-y-2 text-sm">高度<TextInput aria-label="画布高度" type="number" min="1" suffix="px" value={height} onChange={event => setHeight(event.target.value)} /></label></div>
    </Dialog>
  </div>
}
initI18n()
createRoot(document.getElementById('root')!).render(<ErrorBoundary><McpProviders><App /></McpProviders></ErrorBoundary>)
