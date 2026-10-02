import {copyFile, mkdir, readFile, writeFile} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const dist=path.join(root,'web','dist-browser');
await mkdir(dist,{recursive:true});
try{await readFile(path.join(dist,'index.html'),'utf8')}
catch(error){
  if(error.code!=='ENOENT')throw error;
  await copyFile(path.join(dist,'browser.html'),path.join(dist,'index.html'));
}
for(const [source,destination] of [
  ['LICENSE','LICENSE.txt'],
  ['ATTRIBUTION.md','ATTRIBUTION.md'],
  ['docs/WEB_PRIVACY.md','PRIVACY.md'],
])await copyFile(path.join(root,source),path.join(dist,destination));
await writeFile(path.join(dist,'.nojekyll'),'');
let revision=process.env.GITHUB_SHA||'uncommitted';
if(revision==='uncommitted'){
  try{revision=execFileSync('git',['rev-parse','HEAD'],{cwd:root,encoding:'utf8',stdio:['ignore','pipe','ignore']}).trim()}
  catch{}
}
const repository=process.env.GITHUB_REPOSITORY||null;
const source=repository?`${process.env.GITHUB_SERVER_URL||'https://github.com'}/${repository}/tree/${revision}`:null;
await writeFile(path.join(dist,'build-info.json'),JSON.stringify({
  format:'r-tavotto-browser-build',revision,repository,source,
  generated_at:new Date().toISOString(),runtime:'WebR in the browser',
  license:'AGPL-3.0-only',
},null,2)+'\n');
console.log('Prepared Pages metadata and license files.');
