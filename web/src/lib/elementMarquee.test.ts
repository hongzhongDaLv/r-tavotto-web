import { describe, expect, it } from 'vitest'

import type { ManifestElement } from './api'
import { elementMarqueeHit, elementMarqueeModeForDrag } from './elementMarquee'

const element = (patch: Partial<ManifestElement> = {}): ManifestElement => ({
  gid: 'text-1',
  role: 'text',
  label: 'label',
  bbox: [0.4, 0.4, 0.2, 0.2],
  editable: [],
  draggable: true,
  ...patch,
})

describe('elementMarqueeHit：CAD 窗口 / 交叉框选', () => {
  const whole = { x: 0.3, y: 0.3, w: 0.4, h: 0.4 }
  const partial = { x: 0.55, y: 0.35, w: 0.3, h: 0.3 }

  it('从左往右是窗口框，从右往左是交叉框', () => {
    expect(elementMarqueeModeForDrag(100, 300)).toBe('window')
    expect(elementMarqueeModeForDrag(300, 100)).toBe('crossing')
    expect(elementMarqueeModeForDrag(100, 100)).toBe('window')
  })

  it('窗口框选只收下完全落入框内的对象', () => {
    expect(elementMarqueeHit(element(), whole, 'window')).toBe(true)
    expect(elementMarqueeHit(element(), partial, 'window')).toBe(false)
  })

  it('交叉框选碰到对象即选中', () => {
    expect(elementMarqueeHit(element(), partial, 'crossing')).toBe(true)
  })

  it('交叉框选按真实路径命中，不把路径包围盒里的空白算进去', () => {
    const line = element({
      role: 'line',
      bbox: [0.2, 0.2, 0.6, 0.6],
      geometry: {
        kind: 'polyline',
        paths: [{ points: [[0.2, 0.2], [0.8, 0.8]], closed: false }],
        fill: false,
        stroke: true,
      },
    })
    expect(elementMarqueeHit(line, { x: 0.7, y: 0.28, w: 0.08, h: 0.08 }, 'crossing')).toBe(false)
    expect(elementMarqueeHit(line, { x: 0.45, y: 0.45, w: 0.08, h: 0.08 }, 'crossing')).toBe(true)
  })

  it('树内语义图层不因大包围框进入画布框选', () => {
    const parent = element({ canvas_selectable: false, bbox: [0.1, 0.1, 0.8, 0.8] })
    expect(elementMarqueeHit(parent, whole, 'window')).toBe(false)
    expect(elementMarqueeHit(parent, partial, 'crossing')).toBe(false)
  })

  it('坐标轴框是结构容器，只能从对象树选择，不进入画布框选', () => {
    const axes = element({ role: 'axes', bbox: [0.1, 0.1, 0.8, 0.8] })
    expect(elementMarqueeHit(axes, partial, 'crossing')).toBe(false)
    expect(elementMarqueeHit(axes, { x: 0.05, y: 0.05, w: 0.9, h: 0.9 }, 'window')).toBe(false)
  })
})
