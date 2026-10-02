import {act,createRef} from 'react'
import {createRoot} from 'react-dom/client'
import {it,expect} from 'vitest'
import {TextActionRow} from './TextActions'
import {applyLocale} from '@/i18n'

it('retains upstream mathtext actions by default, but R plain text exposes only valid actions',async()=>{
  await applyLocale('zh-CN')
  const host=document.createElement('div');document.body.appendChild(host)
  const root=createRoot(host),taRef=createRef<HTMLTextAreaElement>()
  try {
    await act(async()=>root.render(<TextActionRow text="x" taRef={taRef} onChange={()=>{}}/>))
    expect(host.querySelector('[aria-label="上标"]')).not.toBeNull()
    expect(host.querySelector('[aria-label="下标"]')).not.toBeNull()
    await act(async()=>root.render(<TextActionRow allowMath={false} text="x" taRef={taRef} onChange={()=>{}}/>))
    expect(host.querySelector('[aria-label="上标"]')).toBeNull()
    expect(host.querySelector('[aria-label="下标"]')).toBeNull()
    expect(host.querySelector('[aria-label="插入换行"]')).not.toBeNull()
  } finally {await act(async()=>root.unmount());host.remove()}
})
