import {describe,expect,it} from 'vitest'
import {safeRelativePath,readSelectedFiles} from './browserFiles'

function selectedFile(name:string,bytes:number[],relative='') {
  return {name,size:bytes.length,webkitRelativePath:relative,arrayBuffer:async()=>new Uint8Array(bytes).buffer} as File
}
describe('explicit browser file import',()=>{
  it('keeps directory structure and exact binary bytes without querying a computer path',async()=>{
    const files=await readSelectedFiles([selectedFile('figure.R',[10,13,255],'project/scripts/figure.R'),selectedFile('data.csv',[1,0,4],'project/data/data.csv')])
    expect(files.map(f=>f.path)).toEqual(['project/scripts/figure.R','project/data/data.csv'])
    expect(Array.from(files[0].data)).toEqual([10,13,255])
  })
  it('rejects traversal and absolute computer paths',()=>{
    for(const path of ['../secret','a/../secret','C:\\Users\\person\\data.csv','/etc/data','a//b','a/./b','x\u0000.csv'])expect(()=>safeRelativePath(path)).toThrow()
    expect(safeRelativePath('./project\\data.csv')).toBe('project/data.csv')
  })
  it('does not silently merge conflicting paths in a single upload',async()=>{
    await expect(readSelectedFiles([selectedFile('data.csv',[1]),selectedFile('data.csv',[2])])).rejects.toThrow('重复文件路径')
  })
  it('rejects oversized selection before reading bytes',async()=>{
    let read=false
    const file={name:'large.bin',size:151*1024*1024,webkitRelativePath:'',arrayBuffer:async()=>{read=true;return new ArrayBuffer(0)}} as File
    await expect(readSelectedFiles([file])).rejects.toThrow('150 MB')
    expect(read).toBe(false)
  })
})
