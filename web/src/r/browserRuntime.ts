import engineSource from '../../../r-adapter/engine.R?raw'
import propertiesSource from '../../../r-adapter/visual-properties.R?raw'
import type { EngineRenderResponse, Manifest } from '@/lib/api'

/** Fixed ABI: this Wasm release and its compatible package repository travel together. */
export const WEBR_VERSION = '0.6.0'
export const WEBR_URL = `https://webr.r-wasm.org/v${WEBR_VERSION}/`
const PACKAGE_REPOSITORY = 'https://repo.r-wasm.org/'
const PROJECT_ROOT = '/project'
const OUTPUT_ROOT = '/tavotto-output'
const ENGINE_ROOT = '/tavotto-engine'
const encoder = new TextEncoder()
const decoder = new TextDecoder()

export interface BrowserFile { path: string; data: Uint8Array }
export interface BrowserOpenOptions {
  files: BrowserFile[]
  scriptPath: string
  object?: string
  /** CSS pixels at 96 px/in; used ONLY when the script declares no device dimensions. */
  fallbackSizePx?: [number, number]
}
export interface BrowserRuntimeStatus {
  stage: 'idle' | 'initializing' | 'packages' | 'opening' | 'rendering' | 'exporting' | 'ready' | 'error'
  message: string
  error?: string
  packages?: string[]
}
export type BrowserOpenResult =
  | { kind: 'ready'; response: EngineRenderResponse; object: string; sourceHash: string }
  | { kind: 'choose-object'; objects: string[] }
  | { kind: 'choose-size'; object: string; reason?: 'conflicting_export_sizes' | 'missing_export_size' }
export interface BrowserExportFile { name: string; bytes: Uint8Array; mime: string }
export interface BrowserExportResult { files: BrowserExportFile[]; code: string }
interface PortableProject {
  format: 'tavotto-r-browser'
  version: 1
  runtimeVersion: string
  scriptPath: string
  object?: string
  fallbackSizePx?: [number, number]
  files: { path: string; base64: string; sha256: string }[]
  patches: unknown[]
}
interface WebRInstance {
  init(): Promise<void>
  close(): void
  installPackages(names: string[], options?: { repos?: string[]; quiet?: boolean }): Promise<void>
  evalRString(code: string): Promise<string>
  evalRVoid(code: string): Promise<void>
  stream(): AsyncIterable<{ type: string; data?: unknown }>
  FS: {
    mkdir(path: string): Promise<unknown>
    writeFile(path: string, bytes: Uint8Array): Promise<void>
    readFile(path: string): Promise<Uint8Array>
  }
}
interface WebRModule {
  WebR: new (options: { baseUrl: string; repoUrl: string; channelType: number; interactive: boolean }) => WebRInstance
  ChannelType: { PostMessage: number }
}
interface RawResponse {
  ok: boolean; error?: string; needs_object?: boolean; objects?: string[]
  needs_size?: boolean; reason?: 'conflicting_export_sizes' | 'missing_export_size'; object?: string; rev?: number; manifest?: Manifest
  fragments?: { gid: string; parent?: string; svg: string }[]; warnings?: string[]
}

const rString = (value: string) => JSON.stringify(value)
export function browserRelativePath(path: string): string {
  const normalized = path.replaceAll('\\', '/').replace(/^\.\//, '')
  if (!normalized || normalized.startsWith('/') || /^[a-z]:/i.test(normalized) || /[\x00-\x1f]/.test(normalized))
    throw Error('选择文件或目录时请保留相对路径；浏览器无法读取电脑上的绝对路径。')
  if (normalized.split('/').some((part) => !part || part === '..' || part === '.'))
    throw Error(`文件路径无效：${path}`)
  return normalized
}
async function sha256(bytes: Uint8Array): Promise<string> {
  const copy = new Uint8Array(bytes)
  const hash = await crypto.subtle.digest('SHA-256', copy)
  return Array.from(new Uint8Array(hash), (byte) => byte.toString(16).padStart(2, '0')).join('')
}
function toBase64(bytes: Uint8Array): string {
  let value = ''
  for (let i = 0; i < bytes.length; i += 32768) value += String.fromCharCode(...bytes.subarray(i, i + 32768))
  return btoa(value)
}
function fromBase64(value: string): Uint8Array {
  return Uint8Array.from(atob(value), (letter) => letter.charCodeAt(0))
}
function escapeXml(value: string): string {
  return value.replaceAll('&', '&amp;').replaceAll('"', '&quot;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')
}
/** Same fragment composition contract as the native R session transport. */
export function composeBrowserRender(raw: RawResponse): EngineRenderResponse {
  if (!raw.manifest || typeof raw.rev !== 'number' || !Array.isArray(raw.fragments))
    throw Error('R 引擎返回了不完整的图形结构。')
  const [width, height] = raw.manifest.size_mm.map((mm) => mm * 72 / 25.4)
  const grouped = new Map<string, string[]>()
  const parts = raw.fragments.map(({ gid, svg, parent }, index) => {
    let inner = svg.replace(/^[\s\S]*?<svg[^>]*>/, '').replace(/<\/svg>\s*$/, '')
    for (const match of Array.from(inner.matchAll(/\bid="([^"]+)"/g))) {
      const id = match[1], prefixed = `r${index}_${id}`
      inner = inner.replaceAll(`id="${id}"`, `id="${prefixed}"`)
        .replaceAll(`#${id}"`, `#${prefixed}"`).replaceAll(`#${id})`, `#${prefixed})`)
    }
    const fragment = `<g id="${escapeXml(gid)}">${inner}</g>`
    if (!parent) return fragment
    const group = grouped.get(parent) ?? []
    group.push(fragment); grouped.set(parent, group)
    return group.length === 1 ? { parent } : null
  })
  const content = parts.map((part) => typeof part === 'string' ? part : part ?
    `<g id="${escapeXml(part.parent)}">${grouped.get(part.parent)!.join('')}</g>` : '').join('')
  return {
    rev: raw.rev, manifest: raw.manifest, warnings: raw.warnings ?? [],
    svg: `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" overflow="visible" viewBox="0 0 ${width} ${height}">${content}</svg>`,
    timings: {},
  }
}

export class BrowserRRuntime {
  private instance?: WebRInstance
  private initializing?: Promise<void>
  private queue: Promise<void> = Promise.resolve()
  private generation = 0
  private listeners = new Set<(status: BrowserRuntimeStatus) => void>()
  private options?: BrowserOpenOptions
  private hashes = new Map<string, string>()
  private object?: string
  private patches: unknown[] = []
  private currentStatus: BrowserRuntimeStatus = { stage: 'idle', message: '' }
  get status(): BrowserRuntimeStatus { return this.currentStatus }
  subscribe(listener: (status: BrowserRuntimeStatus) => void): () => void {
    this.listeners.add(listener); listener(this.currentStatus)
    return () => { this.listeners.delete(listener) }
  }
  private emit(status: BrowserRuntimeStatus) {
    this.currentStatus = status
    for (const listener of this.listeners) listener(status)
  }
  initialize(): Promise<void> {
    if (this.initializing) return this.initializing
    const generation = this.generation
    this.emit({ stage: 'initializing', message: '首次使用正在准备浏览器 R 运行环境…' })
    this.initializing = (async () => {
      const module = await import(/* @vite-ignore */ `${WEBR_URL}webr.mjs`) as WebRModule
      if (generation !== this.generation) throw new DOMException('已取消加载', 'AbortError')
      const instance = new module.WebR({ baseUrl: WEBR_URL, repoUrl: PACKAGE_REPOSITORY,
        channelType: module.ChannelType.PostMessage, interactive: false })
      this.instance = instance
      await instance.init()
      if (generation !== this.generation) throw new DOMException('已取消加载', 'AbortError')
      // Drain worker output so source messages/package progress cannot accumulate unboundedly.
      void (async () => {
        try { for await (const output of instance.stream()) {
          if (generation !== this.generation || output.type === 'closed') break
        } } catch { /* The worker is intentionally terminated by reset. */ }
      })()
      await this.install(['ggplot2', 'jsonlite', 'digest', 'png', 'svglite'])
      await this.mkdir(ENGINE_ROOT)
      await instance.FS.writeFile(`${ENGINE_ROOT}/engine.R`, encoder.encode(engineSource))
      await instance.FS.writeFile(`${ENGINE_ROOT}/visual-properties.R`, encoder.encode(propertiesSource))
      await instance.evalRVoid(`options(tavotto.browser=TRUE, tavotto.engine.base=${rString(ENGINE_ROOT)},
        repos=c(CRAN=${rString(PACKAGE_REPOSITORY)}), device=function(...) grDevices::pdf(file=NULL))
        source(${rString(`${ENGINE_ROOT}/engine.R`)}, encoding="UTF-8")`)
      this.emit({ stage: 'ready', message: '浏览器 R 已准备好' })
    })().catch((error: unknown) => {
      if (generation === this.generation) {
        this.initializing = undefined
        this.instance?.close(); this.instance = undefined
        this.emit({ stage: 'error', message: '浏览器 R 加载失败', error: String(error) })
      }
      throw error
    })
    return this.initializing
  }
  private async mkdir(path: string) {
    let current = ''
    for (const part of path.split('/').filter(Boolean)) {
      current += `/${part}`
      try { await this.instance!.FS.mkdir(current) } catch { /* Already present; writes still verify it. */ }
    }
  }
  private async install(packages: string[]) {
    const names = [...new Set(packages)].filter((name) => /^[A-Za-z][A-Za-z0-9.]*$/.test(name))
    if (!names.length) return
    const missing = JSON.parse(await this.instance!.evalRString(`json <- function(x) paste0('[',
      paste(sprintf('"%s"',x),collapse=','),']')
      pkgs <- c(${names.map(rString).join(',')})
      json(pkgs[!vapply(pkgs, requireNamespace, quietly=TRUE, FUN.VALUE=logical(1))])`)) as string[]
    if (!missing.length) return
    this.emit({ stage: 'packages', message: `正在准备 R 绘图依赖：${missing.join('、')}`, packages: missing })
    try {
      await this.instance!.installPackages(missing, { repos: [PACKAGE_REPOSITORY], quiet: true })
      const unavailable = JSON.parse(await this.instance!.evalRString(`json(pkgs[!vapply(pkgs, requireNamespace,
        quietly=TRUE, FUN.VALUE=logical(1))])`)) as string[]
      if (unavailable.length) throw Error(unavailable.join(', '))
    } catch (error) {
      throw Error(`浏览器 R 无法准备 ${missing.join('、')}。该包可能尚无 WebAssembly 版本，或依赖下载失败。${String(error)}`)
    }
  }
  private run<T>(stage: BrowserRuntimeStatus['stage'], message: string, operation: () => Promise<T>): Promise<T> {
    const generation = this.generation
    const next = this.queue.catch(() => {}).then(async () => {
      if (generation !== this.generation) throw new DOMException('会话已关闭', 'AbortError')
      await this.initialize()
      if (generation !== this.generation) throw new DOMException('会话已关闭', 'AbortError')
      this.emit({ stage, message })
      try {
        const result = await operation()
        if (generation !== this.generation) throw new DOMException('会话已关闭', 'AbortError')
        this.emit({ stage: 'ready', message: '' })
        return result
      } catch (error) {
        if (generation === this.generation) this.emit({ stage: 'error', message: '操作未完成', error: String(error) })
        throw error
      }
    })
    this.queue = next.then(() => {}, () => {})
    return next
  }
  private async request(value: object): Promise<RawResponse> {
    const data = JSON.parse(await this.instance!.evalRString(`tavotto_handle_json(${rString(JSON.stringify(value))})`)) as RawResponse
    if (!data.ok) throw Error(data.error ?? 'R 引擎执行失败')
    return data
  }
  private async openResult(raw: RawResponse): Promise<BrowserOpenResult> {
    if (raw.needs_object) return { kind: 'choose-object', objects: raw.objects ?? [] }
    if (raw.needs_size) { this.object = raw.object; return { kind: 'choose-size', object: raw.object!, reason: raw.reason } }
    this.object = raw.object
    const response = composeBrowserRender(raw)
    // Virtual paths are intentionally relative at the transport/persistence boundary.
    response.manifest.source_script = this.options!.scriptPath
    await this.verifyOriginalFiles()
    return { kind: 'ready', response, object: this.object!, sourceHash: this.hashes.get(this.options!.scriptPath)! }
  }
  open(options: BrowserOpenOptions): Promise<BrowserOpenResult> {
    return this.run('opening', '正在执行 R 脚本并读取图形对象…', async () => {
      const scriptPath = browserRelativePath(options.scriptPath)
      const files = options.files.map(({ path, data }) => ({ path: browserRelativePath(path), data: new Uint8Array(data) }))
      if (!files.some((file) => file.path === scriptPath)) throw Error('所选 R 脚本未包含在导入文件中。')
      if (new Set(files.map((file) => file.path)).size !== files.length) throw Error('导入文件中存在重复相对路径。')
      this.options = { ...options, scriptPath, files }; this.object = options.object; this.patches = []; this.hashes.clear()
      await this.instance!.evalRVoid(`unlink(${rString(PROJECT_ROOT)},recursive=TRUE);unlink(${rString(OUTPUT_ROOT)},recursive=TRUE)
        state <- new.env(); state$rev <- 0L`)
      for (const root of [PROJECT_ROOT, OUTPUT_ROOT]) await this.mkdir(root)
      for (const file of files) {
        const path = `${PROJECT_ROOT}/${file.path}`
        await this.mkdir(path.slice(0, path.lastIndexOf('/')))
        await this.instance!.FS.writeFile(path, file.data)
        this.hashes.set(file.path, await sha256(file.data))
        if (/\.(ttf|otf)$/i.test(file.path)) {
          await this.mkdir('/home/web_user/fonts')
          await this.instance!.FS.writeFile(`/home/web_user/fonts/${file.path.split('/').at(-1)}`, file.data)
        }
      }
      const paths = files.filter((file) => /\.r$/i.test(file.path)).map((file) => `${PROJECT_ROOT}/${file.path}`)
      const packages = JSON.parse(await this.instance!.evalRString(`local({
        packages <- character(); visited <- character(); uploaded <- c(${paths.map(rString).join(',')})
        scan <- function(path) {
          path <- normalizePath(path,mustWork=FALSE)
          if(path %in% visited || !file.exists(path))return(invisible(NULL))
          visited <<- c(visited,path)
          walk(parse(path,encoding='UTF-8'),path)
        }
        walk <- function(node,current) {
          if(is.call(node)) {
            head <- node[[1L]]
            if(is.call(head) && as.character(head[[1L]]) %in% c('::',':::') && length(head)>2L)
              packages <<- c(packages,as.character(head[[2L]]))
            if(is.symbol(head) && as.character(head) %in% c('library','require','requireNamespace') && length(node)>1L) {
              pkg <- node[[2L]]
              if(is.symbol(pkg)||is.character(pkg))packages <<- c(packages,as.character(pkg))
            }
            if(is.symbol(head)&&as.character(head)=='source'&&length(node)>1L) {
              value<-node[[2L]]
              if(is.character(value)&&length(value)==1L) {
                relative<-file.path(dirname(current),value)
                candidates<-uploaded[endsWith(uploaded,paste0('/',value))]
                if(file.exists(relative))scan(relative) else if(length(candidates)==1L)scan(candidates[[1L]])
              }
            }
            if(length(node)>1L)for(i in seq.int(2L,length(node)))
              if(!identical(node[[i]],quote(expr=)))walk(node[[i]],current)
          } else if(is.expression(node)||is.list(node)||is.pairlist(node))
            for(i in seq_along(node))if(!identical(node[[i]],quote(expr=)))walk(node[[i]],current)
        }
        scan(${rString(`${PROJECT_ROOT}/${scriptPath}`)})
        jsonlite::toJSON(unique(packages),auto_unbox=FALSE)
      })`)) as string[]
      await this.install(packages)
      this.emit({ stage: 'opening', message: '正在执行 R 脚本并读取图形对象…' })
      return this.openResult(await this.request({ method: 'open', script: `${PROJECT_ROOT}/${scriptPath}`,
        out: OUTPUT_ROOT, object: options.object, fallback_size_px: options.fallbackSizePx }))
    })
  }
  selectObject(object: string, fallbackSizePx?: [number, number]): Promise<BrowserOpenResult> {
    return this.run('opening', '正在读取所选 ggplot 图形…', async () => {
      if (fallbackSizePx && this.options) this.options.fallbackSizePx = fallbackSizePx
      return this.openResult(await this.request({ method: 'select', object, fallback_size_px: fallbackSizePx }))
    })
  }
  apply(patches: unknown[]): Promise<EngineRenderResponse> {
    const snapshot = structuredClone(patches)
    return this.run('rendering', '正在更新图形…', async () => {
      const response = composeBrowserRender(await this.request({ method: 'apply', patches: snapshot }))
      this.patches = snapshot; response.manifest.source_script = this.options?.scriptPath
      return response
    })
  }
  private async verifyOriginalFiles() {
    for (const [path, original] of this.hashes) {
      const current = await sha256(await this.instance!.FS.readFile(`${PROJECT_ROOT}/${path}`))
      if (current !== original) throw Error(`脚本修改了导入文件 ${path}，无法确认原文件完整性。请调整脚本，将输出写入独立目录。`)
    }
  }
  private async portable(patches: unknown[]): Promise<string> {
    if (!this.options) throw Error('请先导入 R 绘图脚本。')
    await this.verifyOriginalFiles()
    const project: PortableProject = {
      format: 'tavotto-r-browser', version: 1, runtimeVersion: WEBR_VERSION,
      scriptPath: this.options.scriptPath, object: this.object,
      fallbackSizePx: this.options.fallbackSizePx,
      files: this.options.files.map((file) => ({ path: file.path, base64: toBase64(file.data), sha256: this.hashes.get(file.path)! })),
      patches: structuredClone(patches),
    }
    return JSON.stringify(project, null, 2)
  }
  saveProject(patches: unknown[] = this.patches): Promise<string> {
    return this.run('exporting', '正在保存可移植项目…', () => this.portable(patches))
  }
  async loadProject(input: string | Blob): Promise<BrowserOpenResult> {
    const project = JSON.parse(typeof input === 'string' ? input : await input.text()) as PortableProject
    if (project.format !== 'tavotto-r-browser' || project.version !== 1 || !Array.isArray(project.files) || !Array.isArray(project.patches))
      throw Error('该文件不是包含原始脚本与数据的浏览器版 Tavotto R 项目。')
    const files: BrowserFile[] = []
    for (const file of project.files) {
      const data = fromBase64(file.base64)
      if (await sha256(data) !== file.sha256) throw Error(`项目文件校验失败：${file.path}`)
      files.push({ path: browserRelativePath(file.path), data })
    }
    const result = await this.open({ files, scriptPath: project.scriptPath, object: project.object, fallbackSizePx: project.fallbackSizePx })
    if (result.kind !== 'ready') return result
    return { ...result, response: await this.apply(project.patches) }
  }
  export(patches: unknown[] = this.patches): Promise<BrowserExportResult> {
    const snapshot = structuredClone(patches)
    return this.run('exporting', '正在生成 SVG、PDF、PNG 和对应 R 代码…', async () => {
      if (JSON.stringify(snapshot) !== JSON.stringify(this.patches)) {
        await this.request({ method: 'apply', patches: snapshot }); this.patches = snapshot
      }
      await this.request({ method: 'export' })
      const mime: Record<string, string> = { 'figure.svg': 'image/svg+xml', 'figure.pdf': 'application/pdf',
        'figure.png': 'image/png', 'figure-edited.R': 'text/plain', 'patches.json': 'application/json' }
      const files: BrowserExportFile[] = []
      for (const [name, type] of Object.entries(mime)) files.push({ name, mime: type,
        bytes: await this.instance!.FS.readFile(`${OUTPUT_ROOT}/${name}`) })
      if (this.object?.startsWith('.tavotto_export_')) files.push({ name: 'figure-source.rds', mime: 'application/octet-stream',
        bytes: await this.instance!.FS.readFile(`${OUTPUT_ROOT}/figure-source.rds`) })
      const project = await this.portable(snapshot)
      files.push({ name: 'project.tavotto-r.json', mime: 'application/json', bytes: encoder.encode(project) })
      return { files, code: decoder.decode(files.find((file) => file.name === 'figure-edited.R')!.bytes) }
    })
  }
  code(patches: unknown[] = this.patches): Promise<string> {
    const snapshot = structuredClone(patches)
    return this.run('exporting', '正在生成对应 R 代码…', async () => {
      if (JSON.stringify(snapshot) !== JSON.stringify(this.patches)) {
        await this.request({ method: 'apply', patches: snapshot }); this.patches = snapshot
      }
      await this.request({ method: 'code' })
      return decoder.decode(await this.instance!.FS.readFile(`${OUTPUT_ROOT}/figure-edited.R`))
    })
  }
  /** GitHub Pages uses PostMessage: terminating the worker is the real cancellation boundary. */
  reset(): void {
    this.generation++; this.instance?.close(); this.instance = undefined; this.initializing = undefined
    this.queue = Promise.resolve(); this.options = undefined; this.patches = []; this.object = undefined; this.hashes.clear()
    this.emit({ stage: 'idle', message: '' })
  }
}
export const browserRuntime = new BrowserRRuntime()
