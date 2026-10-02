import { chromium } from '../web/node_modules/@playwright/test/index.mjs'
import {mkdir,writeFile,readFile} from 'node:fs/promises'
import assert from 'node:assert/strict'
import {fileURLToPath} from 'node:url'

const url=process.env.BROWSER_TEST_URL||'http://127.0.0.1:8771/browser.html'
const output=new URL('./browser-ui-results/',import.meta.url)
await mkdir(output,{recursive:true})
const browser=await chromium.launch({executablePath:process.env.EDGE_PATH||'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',headless:true})
try {
  const page=await browser.newPage({viewport:{width:1500,height:1000}})
  const failures=[],errors=[],network=[]
  page.on('pageerror',e=>errors.push(e.message))
  page.on('requestfailed',r=>failures.push({url:r.url(),error:r.failure()?.errorText}))
  page.on('request',r=>{if(r.method()==='POST'||r.url().includes('/api/'))network.push({url:r.url(),method:r.method()})})
  await page.goto(url,{waitUntil:'domcontentloaded'})
  await page.getByTestId('browser-import').waitFor()
  await page.screenshot({path:fileURLToPath(new URL('import.png',output))}).catch(e=>console.log('SCREENSHOT_WARNING',e.message))
  await page.getByTestId('open-example').click()
  try {
    await page.waitForFunction(()=>document.querySelector('[data-testid="browser-editor"]')||document.querySelector('[role="alert"]'),undefined,{timeout:180000})
    if(await page.getByRole('alert').count())throw Error(await page.getByRole('alert').innerText())
  }
  catch(e){
    const failure={text:await page.locator('body').innerText(),errors,failures,network}
    await writeFile(new URL('failure.json',output),JSON.stringify(failure,null,2))
    console.log('BROWSER_UI_FAILURE',JSON.stringify(failure))
    await page.screenshot({path:fileURLToPath(new URL('failure.png',output))}).catch(()=>{})
    throw e
  }
  await page.getByTestId('export-figure').waitFor({state:'visible'})
  async function ready(){
    await page.waitForFunction(()=>{
      const button=document.querySelector('[data-testid="export-figure"]')
      return button && !button.disabled
    },undefined,{timeout:90000})
  }
  await ready()
  const pageSize=async()=>{
    await page.getByTestId('select-page').click()
    return Promise.all([0,1].map(i=>page.locator('[data-prop="size_mm"] input').nth(i).inputValue().then(Number)))
  }
  const frame=async()=>{
    await page.getByTestId('select-frame').click()
    return Promise.all(['x','y','width','height'].map(key=>page.locator(`input[data-inspector-prop="axes-frame-${key}"]`).inputValue().then(Number)))
  }
  const sheet=()=>page.locator('[data-page-sheet]').evaluate(e=>({width:e.style.width,height:e.style.height}))
  async function change(locator,value){await locator.fill(String(value));await locator.press('Enter');await ready()}
  const initialPage=await pageSize(),initialFrame=await frame(),initialSheet=await sheet()
  assert.deepEqual(initialPage,[900,600],'R script export must define initial page')
  await page.getByTestId('select-page').click()
  await change(page.locator('[data-prop="size_mm"] input').nth(0),1000)
  await change(page.locator('[data-prop="size_mm"] input').nth(1),700)
  const enlargedSheet=await sheet(),afterPageFrame=await frame()
  afterPageFrame.forEach((value,i)=>assert.ok(Math.abs(value-initialFrame[i])<0.15,'Canvas resize changed frame component '+i))
  assert.notDeepEqual(enlargedSheet,initialSheet,'White page size did not change')
  const targetFrameWidth=Math.round(initialFrame[2]-60)
  await change(page.locator('input[data-inspector-prop="axes-frame-width"]'),targetFrameWidth)
  const editedFrame=await frame()
  assert.ok(Math.abs(editedFrame[2]-targetFrameWidth)<0.15,'Frame width did not follow input')
  assert.deepEqual(await pageSize(),[1000,700],'Frame resize changed output page')
  await page.getByTestId('view-code').click()
  await page.getByTestId('r-code').waitFor()
  const replay=await page.getByTestId('r-code').innerText()
  const nativeDraw=replay.match(/draw_figure\(g,([0-9.]+),([0-9.]+),structure\(c\(([^)]+)\)/)
  assert.ok(nativeDraw,'Replay must use explicit native grid page/frame geometry')
  assert.ok(Math.abs(Number(nativeDraw[1])*96/25.4-1000)<0.01)
  assert.ok(Math.abs(Number(nativeDraw[2])*96/25.4-700)<0.01)
  const replayFrame=nativeDraw[3].split(',').map(Number).map(mm=>mm*96/25.4)
  replayFrame.forEach((value,i)=>assert.ok(Math.abs(value-editedFrame[i])<0.15,'Replay code differs from frame input '+i))
  await page.keyboard.press('Escape')
  const projectEvent=page.waitForEvent('download')
  await page.getByTestId('save-project').click()
  const projectDownload=await projectEvent
  const projectBytes=await readFile(await projectDownload.path())
  const project=JSON.parse(projectBytes.toString())
  assert.equal(project.format,'tavotto-r-browser')
  assert.ok(project.files.some(file=>file.path==='example.R'&&file.sha256))
  assert.ok(project.patches.some(patch=>patch.prop==='size_mm'))
  assert.ok(project.patches.some(patch=>patch.prop==='frame_mm'))
  await page.getByTestId('close-figure').click()
  await page.getByRole('button',{name:'返回导入',exact:true}).click()
  await page.getByTestId('input-project').setInputFiles({name:'saved.tavotto-r.json',mimeType:'application/json',buffer:projectBytes})
  await page.getByTestId('browser-editor').waitFor({timeout:180000})
  await ready()
  assert.deepEqual(await pageSize(),[1000,700])
  const restoredFrame=await frame()
  restoredFrame.forEach((value,i)=>assert.ok(Math.abs(value-editedFrame[i])<0.15,'Portable project lost frame component '+i))
  await page.getByTestId('export-figure').click()
  await page.getByTestId('download-figure.svg').waitFor({timeout:90000})
  const exports={}
  for(const extension of ['svg','png','pdf']){
    const event=page.waitForEvent('download')
    await page.getByTestId('download-figure.'+extension).click()
    const download=await event,bytes=await readFile(await download.path())
    assert.ok(bytes.length>1000,extension+' export is empty')
    let dimensions
    if(extension==='png'){
      assert.equal(bytes.subarray(0,8).toString('hex'),'89504e470d0a1a0a')
      dimensions=[bytes.readUInt32BE(16),bytes.readUInt32BE(20)]
      assert.deepEqual(dimensions,[6250,4375],'600 dpi raster must match 1000x700 CSS px')
    }
    if(extension==='pdf'){
      assert.equal(bytes.subarray(0,5).toString(),'%PDF-')
      const box=bytes.toString('latin1').match(/\/MediaBox\s*\[\s*0\s+0\s+([0-9.]+)\s+([0-9.]+)\s*\]/)
      assert.ok(box,'PDF page size must be explicit')
      dimensions=[Number(box[1]),Number(box[2])]
      assert.deepEqual(dimensions,[750,525])
    }
    if(extension==='svg'){
      const root=bytes.toString().match(/<svg\b[^>]+>/)?.[0]
      assert.ok(root,'SVG root is missing')
      dimensions=['width','height'].map(key=>Number(root.match(new RegExp(key+'="([0-9.]+)pt"'))?.[1]))
      assert.deepEqual(dimensions,[750,525])
    }
    exports[extension]={bytes:bytes.length,dimensions}
  }
  await page.keyboard.press('Escape')
  await page.evaluate(()=>{IDBFactory.prototype.open=()=>{throw new DOMException('Storage disabled for verification','QuotaExceededError')}})
  const storageFallbackEvent=page.waitForEvent('download')
  await page.getByTestId('save-project').click()
  const fallbackDownload=await storageFallbackEvent
  const fallbackProject=JSON.parse((await readFile(await fallbackDownload.path())).toString())
  assert.deepEqual(fallbackProject.patches,project.patches,'Storage failure must not block portable download')
  await page.getByRole('status').filter({hasText:'浏览器存储不可用'}).waitFor()
  await page.screenshot({path:fileURLToPath(new URL('editor.png',output))}).catch(e=>console.log('SCREENSHOT_WARNING',e.message))
  const dom=await page.evaluate(()=>({text:document.body.innerText,inputs:[...document.querySelectorAll('input')].map(e=>({label:e.getAttribute('aria-label'),title:e.title,placeholder:e.placeholder,type:e.type,value:e.value,testid:e.getAttribute('data-testid')})),testids:[...document.querySelectorAll('[data-testid]')].map(e=>e.getAttribute('data-testid'))}))
  const report={url,errors,failures,network,initialPage,initialFrame,initialSheet,enlargedSheet,afterPageFrame,editedFrame,restoredFrame,projectPatches:project.patches,exports,storageFailureDownload:true,dom}
  await writeFile(new URL('initial.json',output),JSON.stringify(report,null,2))
  if(errors.length)throw Error(errors.join(';'))
  if(network.length)throw Error('Browser app attempted backend POST/API: '+JSON.stringify(network))
  console.log('BROWSER_UI_FLOW_PASS',JSON.stringify({url,errors,failures,network,initialPage,initialFrame,initialSheet,enlargedSheet,editedFrame,restoredFrame,exports}))
} finally {await browser.close()}
