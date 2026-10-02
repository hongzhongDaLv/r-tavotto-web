import {chromium} from '../web/node_modules/@playwright/test/index.mjs'
import {mkdir,writeFile} from 'node:fs/promises'
import assert from 'node:assert/strict'
import {fileURLToPath} from 'node:url'
const url=process.env.CAD_TEST_URL||'http://127.0.0.1:8779/tests/cad-browser.html'
const output=new URL('./browser-cad-results/',import.meta.url)
await mkdir(output,{recursive:true})
const browser=await chromium.launch({executablePath:process.env.EDGE_PATH||'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',headless:true})
try{
  const page=await browser.newPage({viewport:{width:1400,height:1000}})
  const errors=[]
  page.on('pageerror',e=>errors.push(e.message))
  await page.goto(url,{waitUntil:'domcontentloaded'})
  await page.waitForFunction(()=>window.cadHarness?.ready)
  const original=await page.evaluate(()=>window.cadHarness.state().doc)
  const drag=async(from,to,mode,expected)=>{
    const a=await page.evaluate(p=>window.cadHarness.point(...p),from)
    const b=await page.evaluate(p=>window.cadHarness.point(...p),to)
    const target=await page.evaluate(p=>document.elementFromPoint(p.x,p.y)?.outerHTML.slice(0,350),a)
    // Use real browser hit testing and pointer events, never dispatch to a chosen element.
    await page.mouse.move(a.x,a.y);await page.mouse.down()
    await page.mouse.move(b.x,b.y,{steps:8})
    try {
      assert.equal(await page.locator('[data-marquee-mode]').getAttribute('data-marquee-mode',{timeout:3000}),mode)
    } catch(error) {
      await page.screenshot({path:fileURLToPath(new URL('failed.png',output)),fullPage:true})
      console.error(JSON.stringify({from,to,a,b,target,state:await page.evaluate(()=>window.cadHarness.state()),errors},null,2))
      throw error
    }
    await page.mouse.up()
    assert.deepEqual((await page.evaluate(()=>window.cadHarness.state())).gids,expected)
  }
  await drag([-.5,.15],[.45,.35],'window',['inside'])
  await drag([1.25,.35],[-.5,.15],'crossing',['inside','partial','diagonal'])
  await drag([-.5,.6],[-.2,.8],'window',['outside'])
  await drag([1.25,.51],[.5,.46],'crossing',['errorbar'])
  await drag([1.25,.18],[.5,.12],'crossing',[])
  const out=await page.evaluate(()=>window.cadHarness.point(-.3,.7))
  await page.mouse.click(out.x,out.y)
  assert.deepEqual((await page.evaluate(()=>window.cadHarness.state())).gids,['outside'])
  const overflow=await page.locator('[data-element-svg] > svg').evaluate(e=>getComputedStyle(e).overflow)
  assert.equal(overflow,'visible')
  assert.equal(await page.locator('[data-editing-panel-outline]').count(),0)
  const state=await page.evaluate(()=>window.cadHarness.state())
  assert.equal(state.doc,original);assert.equal(state.history,0);assert.deepEqual(state.objects,[])
  assert.deepEqual(errors,[])
  await page.screenshot({path:fileURLToPath(new URL('cad-selection.png',output)),fullPage:true})
  await writeFile(new URL('verification.json',output),JSON.stringify({status:'PASS',url,
    cases:['LTR containment from grey','RTL ink crossing from grey','out-of-page selection',
      'errorbar precise path','line bbox blank rejected','out-of-page point selection'],overflow,state,errors},null,2))
  console.log('BROWSER_CAD_PASS')
}finally{await browser.close()}
