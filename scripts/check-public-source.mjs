import {execFileSync} from 'node:child_process';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {publicPathProblem} from './publicBoundary.mjs';

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const files=execFileSync('git',['ls-files','--cached','--others','--exclude-standard','-z'],{
  cwd:root,encoding:'utf8',stdio:['ignore','pipe','inherit'],
}).split('\0').filter(Boolean);
const problems=files.flatMap(filename=>{
  const problem=publicPathProblem(filename);
  return problem?[`${filename}: ${problem}`]:[];
});
if(problems.length){
  console.error('Public source contains forbidden paths:\n'+problems.join('\n'));
  process.exitCode=1;
}else console.log(`PUBLIC_SOURCE_BOUNDARY_PASS (${files.length} source files checked)`);
