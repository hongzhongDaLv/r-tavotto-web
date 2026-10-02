import {readFile, readdir, stat} from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {publicPathProblem,privateProjectPath,textExtension} from './publicBoundary.mjs';

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const dist=process.argv[2]?path.resolve(process.argv[2]):path.join(root,'web','dist-browser');
const problems=[];
const files=[];
async function walk(directory){
  for(const entry of await readdir(directory,{withFileTypes:true})){
    const full=path.join(directory,entry.name);
    const relative=path.relative(dist,full).replaceAll('\\','/');
    if(entry.isSymbolicLink()){problems.push(`${relative}: symlinks are not a Pages artifact`);continue}
    if(entry.isDirectory()){await walk(full);continue}
    files.push(relative);
    const problem=publicPathProblem(relative);
    if(problem)problems.push(`${relative}: ${problem}`);
    if(textExtension.test(relative)){
      const content=await readFile(full,'utf8');
      if(privateProjectPath.test(content))problems.push(`${relative}: contains a private local project path`);
      // Check the actual output package, not unimported source modules. A hard-coded
      // absolute local service URL would make the deployed site depend on localhost.
      if(/https?:\/\/(?:127\.0\.0\.1|localhost|\[::1\])(?::\d+)?(?:\/|["'`\s])/i.test(content))
        problems.push(`${relative}: contains an absolute localhost service URL`);
    }
  }
}
await walk(dist);
for(const required of ['index.html','LICENSE.txt','ATTRIBUTION.md','PRIVACY.md','build-info.json']){
  if(!files.includes(required))problems.push(`${required}: required public metadata is missing`);
  else if((await stat(path.join(dist,required))).size===0)problems.push(`${required}: required public metadata is empty`);
}
if(problems.length){
  console.error('Public build check failed:\n'+problems.join('\n'));
  process.exitCode=1;
}else console.log(`PUBLIC_BROWSER_BUILD_PASS (${files.length} published files checked)`);
