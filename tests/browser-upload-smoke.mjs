import {chromium} from '../web/node_modules/@playwright/test/index.mjs'
import {mkdir,writeFile,readFile} from 'node:fs/promises'
import {createHash} from 'node:crypto'
import assert from 'node:assert/strict'
import {fileURLToPath} from 'node:url'

const url=process.env.BROWSER_TEST_URL||'https://hongzhongdalv.github.io/r-tavotto-web/'
const output=new URL('./browser-upload-results/',import.meta.url)
await mkdir(output,{recursive:true})
const browser=await chromium.launch({executablePath:process.env.EDGE_PATH||'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',headless:true})
const report={url,stage:'starting',network:[],errors:[],failures:[]}
const script=`library(ggplot2)
d <- read.csv("data.csv", stringsAsFactors = FALSE)
p <- ggplot(d, aes(group, value, fill = group)) +
  geom_col(width = 0.6, colour = "#243544") +
  labs(title = "Uploaded CSV from file chooser", x = "Group", y = "Value") +
  theme_classic() + theme(legend.position = "none")
ggsave("upload.svg", p, width = 480, height = 320, units = "px", dpi = 96)
`
const csv='group,value\nA,3\nB,5\nC,7\n'
let page
try {
  page=await browser.newPage({viewport:{width:1440,height:960}})
  page.on('pageerror',error=>report.errors.push(error.message))
  page.on('requestfailed',request=>report.failures.push({url:request.url(),error:request.failure()?.errorText}))
  page.on('request',request=>{
    const requestUrl=request.url()
    if(request.method()==='POST'||/\/api(?:\/|\?|$)/i.test(requestUrl)||/https?:\/\/(?:localhost|127\.0\.0\.1)(?::|\/)/i.test(requestUrl)||/(?:telemetry|posthog|mixpanel|sentry\.io|segment\.com)/i.test(requestUrl))
      report.network.push({url:requestUrl,method:request.method()})
  })
  await page.goto(url,{waitUntil:'domcontentloaded'})
  await page.getByTestId('browser-import').waitFor()
  report.stage='empty-file-list'
  const emptyEvent=page.waitForEvent('filechooser')
  await page.getByTestId('choose-files').click()
  const emptyChooser=await emptyEvent
  assert.ok(emptyChooser.isMultiple(),'Script and CSV should be selectable together')
  // Playwright has no native chooser Cancel API. An empty selection exercises
  // the actual input change handler without uploading any file or starting R.
  await emptyChooser.setFiles([])
  await page.getByTestId('choose-files').waitFor({state:'visible'})
  assert.equal(await page.getByTestId('choose-files').isDisabled(),false)
  assert.equal(await page.getByTestId('open-example').isDisabled(),false)
  report.emptySelection={responsive:true,nativeCancelTested:false}

  report.stage='choose-files'
  const chooserEvent=page.waitForEvent('filechooser')
  await page.getByTestId('choose-files').click()
  const chooser=await chooserEvent
  await chooser.setFiles([
    {name:'upload.R',mimeType:'text/plain',buffer:Buffer.from(script)},
    {name:'data.csv',mimeType:'text/csv',buffer:Buffer.from(csv)},
  ])
  await page.getByText('upload.R',{exact:true}).first().waitFor()
  await page.getByText('data.csv',{exact:true}).first().waitFor()
  assert.equal(await page.getByTestId('open-script').isDisabled(),false)
  report.stage='open-uploaded-script'
  console.log('UPLOAD_TEST opening selected R script and relative CSV in public browser R')
  await page.getByTestId('open-script').click()
  await page.waitForFunction(()=>document.querySelector('[data-testid="browser-editor"]')||document.querySelector('[role="alert"]'),undefined,{timeout:240000})
  if(await page.getByRole('alert').count())throw Error(await page.getByRole('alert').innerText())
  await page.waitForFunction(()=>{
    const button=document.querySelector('[data-testid="export-figure"]')
    return button && !button.disabled
  },undefined,{timeout:90000})
  await page.getByTestId('select-page').click()
  const canvas=await Promise.all([0,1].map(index=>page.locator('[data-prop="size_mm"] input').nth(index).inputValue().then(Number)))
  assert.deepEqual(canvas,[480,320],'Initial canvas must match the uploaded R ggsave size')
  const sheet=await page.locator('[data-page-sheet]').evaluate(element=>({width:element.style.width,height:element.style.height}))
  assert.deepEqual(sheet,{width:'480px',height:'320px'},'White paper must use the R export dimensions')
  report.canvasPx=canvas
  report.sheet=sheet
  report.stage='verify-corresponding-code'
  await page.getByTestId('view-code').click()
  await page.getByTestId('r-code').waitFor({timeout:90000})
  const replay=await page.getByTestId('r-code').innerText()
  assert.ok(/source\("upload\.R"/.test(replay),'Corresponding code must retain the chosen script identity')
  assert.ok(!replay.includes('/project/'),'Virtual absolute paths must not leak into portable replay')
  report.code={referencesUploadR:true,bytes:Buffer.byteLength(replay),hasVirtualAbsolutePath:false}
  await page.keyboard.press('Escape')
  report.stage='verify-portable-imported-files'
  const downloadEvent=page.waitForEvent('download')
  await page.getByTestId('save-project').click()
  const download=await downloadEvent
  const project=JSON.parse((await readFile(await download.path())).toString())
  assert.equal(project.format,'tavotto-r-browser')
  assert.equal(project.scriptPath,'upload.R')
  for(const [path,text] of [['upload.R',script],['data.csv',csv]]) {
    const file=project.files.find(file=>file.path===path)
    assert.ok(file,'Missing uploaded file '+path)
    assert.equal(Buffer.from(file.base64,'base64').toString(),text)
    assert.equal(file.sha256,createHash('sha256').update(text).digest('hex'))
  }
  report.portable={scriptPath:project.scriptPath,files:project.files.map(file=>file.path),originalBytesAndHashesPreserved:true}
  assert.deepEqual(report.network,[],'User files must not leave via upload/API/localhost/telemetry requests')
  assert.deepEqual(report.errors,[],'Unexpected browser runtime errors')
  assert.deepEqual(report.failures,[],'Unexpected failed network requests')
  await page.screenshot({path:fileURLToPath(new URL('upload-editor.png',output))})
  report.stage='PASS'
  await writeFile(new URL('report.json',output),JSON.stringify(report,null,2))
  console.log('BROWSER_UPLOAD_PASS',JSON.stringify(report))
} catch(error) {
  report.stage='FAIL';report.error=String(error)
  if(page) {
    report.visibleText=await page.locator('body').innerText().catch(()=>undefined)
    await page.screenshot({path:fileURLToPath(new URL('failure.png',output))}).catch(()=>{})
  }
  await writeFile(new URL('report.json',output),JSON.stringify(report,null,2))
  throw error
} finally {
  await browser.close()
}
