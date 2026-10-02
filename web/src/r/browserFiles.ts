export interface BrowserFile { path: string; data: Uint8Array }

export function safeRelativePath(value: string): string {
  const path = value.replaceAll('\\', '/').replace(/^\.\//, '')
  if (!path || path.startsWith('/') || /^[A-Za-z]:/.test(path) || /[\x00-\x1f]/.test(path) || path.split('/').some(part => part === '..' || part === '.' || !part)) {
    throw Error('文件路径必须位于所选项目内：' + value)
  }
  return path
}

/** Only files explicitly selected by the user enter the browser's R filesystem. */
export async function readSelectedFiles(files: FileList | File[]): Promise<BrowserFile[]> {
  const picked = Array.from(files)
  const total = picked.reduce((sum, file) => sum + file.size, 0)
  if (total > 150 * 1024 * 1024) throw Error('这次导入超过 150 MB，请选择绘图脚本及其直接依赖的数据。')
  const paths = new Set<string>()
  return Promise.all(picked.map(async file => {
    const path = safeRelativePath(file.webkitRelativePath || file.name)
    if (paths.has(path)) throw Error('重复文件路径：' + path)
    paths.add(path)
    return { path, data: new Uint8Array(await file.arrayBuffer()) }
  }))
}

export function downloadBytes(name: string, data: Uint8Array | string, mime = 'application/octet-stream') {
  const bytes = typeof data === 'string' ? data : new Uint8Array(data).buffer
  const url = URL.createObjectURL(new Blob([bytes], {type: mime}))
  const anchor = document.createElement('a')
  anchor.href = url; anchor.download = name; document.body.append(anchor); anchor.click(); anchor.remove()
  setTimeout(() => URL.revokeObjectURL(url), 30_000)
}

const DB_NAME = 'r-tavotto-browser'
async function openDb(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DB_NAME, 1)
    request.onupgradeneeded = () => request.result.createObjectStore('projects')
    request.onsuccess = () => resolve(request.result)
    request.onerror = () => reject(request.error)
  })
}
export async function saveLastProject(project: unknown): Promise<void> {
  const db = await openDb()
  return new Promise((resolve, reject) => {
    const transaction = db.transaction('projects', 'readwrite')
    transaction.objectStore('projects').put(project, 'last')
    transaction.oncomplete = () => { db.close(); resolve() }
    transaction.onerror = () => { db.close(); reject(transaction.error) }
  })
}
export async function readLastProject(): Promise<unknown | null> {
  const db = await openDb()
  return new Promise((resolve, reject) => {
    const request = db.transaction('projects').objectStore('projects').get('last')
    request.onsuccess = () => { db.close(); resolve(request.result ?? null) }
    request.onerror = () => { db.close(); reject(request.error) }
  })
}
