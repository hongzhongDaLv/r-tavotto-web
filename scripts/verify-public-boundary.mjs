// Exercise the release checker against an isolated synthetic artifact; the
// failure controls ensure the gate is capable of refusing a publishable leak.
import assert from 'node:assert/strict';
import {mkdtemp,mkdir,rm,writeFile} from 'node:fs/promises';
import {spawnSync} from 'node:child_process';
import os from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {publicPathProblem} from './publicBoundary.mjs';

const scriptRoot=path.dirname(fileURLToPath(import.meta.url));
const fixtureRoot=await mkdtemp(path.join(os.tmpdir(),'r-tavotto-public-check-'));
const check=()=>spawnSync(process.execPath,[path.join(scriptRoot,'check-public-build.mjs'),fixtureRoot],{
  encoding:'utf8',windowsHide:true,
});
try{
  for(const name of ['tests/browser-cad-results/verification.json','tests/browser-ui-results/failure.png',
    'tests/native-selection-verification.json','tests/SELECTION_RELEASE_VERIFICATION.md',
    'r-adapter/browser-smoke-report.json'])
    assert.equal(publicPathProblem(name),'local generated verification evidence',name);
  assert.equal(publicPathProblem('web/src/test/fixtures/nativeMarquee.json'),null);
  for(const name of ['index.html','LICENSE.txt','ATTRIBUTION.md','PRIVACY.md','build-info.json'])
    await writeFile(path.join(fixtureRoot,name),name==='build-info.json'?'{}':'public fixture');
  await mkdir(path.join(fixtureRoot,'r'),{recursive:true});
  await writeFile(path.join(fixtureRoot,'r','engine.R'),'# public R engine fixture');
  let result=check();
  assert.equal(result.status,0,result.stderr);
  await mkdir(path.join(fixtureRoot,'docs'),{recursive:true});
  await writeFile(path.join(fixtureRoot,'docs','old-audit.png'),'synthetic unreviewed screenshot');
  result=check();
  assert.equal(result.status,1,'Unreviewed historical screenshots must make the actual publish checker fail.');
  assert.match(result.stderr,/unreviewed historical documentation evidence/);
  await rm(path.join(fixtureRoot,'docs','old-audit.png'));
  await writeFile(path.join(fixtureRoot,'private.rds'),'synthetic forbidden file');
  result=check();
  assert.equal(result.status,1,'A scientific data file must make the actual build checker fail.');
  assert.match(result.stderr,/private\.rds/);
  await rm(path.join(fixtureRoot,'private.rds'));
  await writeFile(path.join(fixtureRoot,'leak.js'),'const path="E:/biodiversity data/private-input";');
  result=check();
  assert.equal(result.status,1,'A known private project path must make the actual build checker fail.');
  assert.match(result.stderr,/private local project path/);
  await writeFile(path.join(fixtureRoot,'leak.js'),'const endpoint="http://127.0.0.1:8768/r-api/open";');
  result=check();
  assert.equal(result.status,1,'A deployed localhost backend dependency must make the actual build checker fail.');
  assert.match(result.stderr,/absolute localhost service URL/);
  await rm(path.join(fixtureRoot,'leak.js'));
  result=check();
  assert.equal(result.status,0,result.stderr);
  console.log('PUBLIC_BOUNDARY_COUNTEREXAMPLES_PASS (clean artifact, generated evidence, old documentation screenshot, private data, path leak, localhost dependency)');
}finally{
  const relative=path.relative(path.resolve(os.tmpdir()),path.resolve(fixtureRoot));
  if(relative.startsWith('r-tavotto-public-check-')&&!relative.includes(path.sep))
    await rm(fixtureRoot,{recursive:true,force:true});
}
