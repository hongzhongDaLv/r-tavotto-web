import { act } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import { TooltipProvider } from '@/components/ui/Tooltip'
import { literal } from '@/i18n'
import { emptyProject, type PanelObject } from '@/types/document'
import { useDocumentStore } from '@/store/documentStore'
import { setPageSize } from '@/store/actions'
import { useViewportStore, mmToWorld } from '@/store/viewportStore'
import { useUiStore } from '@/store/uiStore'
import { useWorkspaceStore } from '@/store/workspace'
import { seedExactRender } from '@/test/renderFixtures'
import { CanvasStage } from './CanvasStage'

vi.mock('@/store/renderScheduler', () => ({ requestRender: vi.fn() }))

class NoopResizeObserver {
  observe() {}
  unobserve() {}
  disconnect() {}
}
globalThis.ResizeObserver = NoopResizeObserver as unknown as typeof ResizeObserver
globalThis.fetch = (async () => new Response('{}', { status: 200 })) as typeof fetch
globalThis.IS_REACT_ACT_ENVIRONMENT = true

let container: HTMLDivElement
let root: Root

const panel = (): PanelObject => ({
  id: 'p1',
  type: 'panel',
  x: 0,
  y: 0,
  w: 100,
  h: 80,
  fileId: 'R-figure.pdf',
  fileKind: 'pdf',
  nativeW: 100,
  nativeH: 80,
  script: 'project.R',
  overrides: [],
})

beforeEach(async () => {
  localStorage.clear()
  useWorkspaceStore.getState().clear()
  useUiStore.getState().setElementPanel(null)
  useViewportStore.setState({ zoom: 1, panX: 0, panY: 0, originX: 0, originY: 0 })
  await useDocumentStore.getState().switchDocument(emptyProject(), 'd_r_page_presentation')
  const p = panel()
  useDocumentStore.getState().commit(literal('Add R figure for test'), (d) => {
    d.page.w = 100
    d.page.h = 80
    d.objects = [p]
  })
  seedExactRender(p, {
    stem: 'R-figure',
    size_mm: [100, 80],
    elements: [
      {
        gid: 'figure',
        role: 'figure',
        label: 'Figure',
        bbox: [0, 0, 1, 1],
        editable: [{ prop: 'size_mm', type: 'pair', value: [100, 80], unit: 'mm' }],
        draggable: false,
        resizable: true,
        canvas_selectable: false,
        r_native: true,
      },
      {
        gid: 'axes_0',
        role: 'axes',
        label: 'Plot frame',
        bbox: [0.2, 0.2, 0.6, 0.5],
        editable: [{ prop: 'frame_mm', type: 'rect', value: [20, 16, 60, 40], unit: 'mm' }],
        draggable: false,
        resizable: true,
        canvas_selectable: false,
        r_native: true,
      },
    ],
  })
  container = document.createElement('div')
  document.body.appendChild(container)
  root = createRoot(container)
})

afterEach(() => {
  act(() => root.unmount())
  container.remove()
})

describe('R 单图画布页面尺寸的可见结果', () => {
  it('改页面宽高会改白纸与网格边界，渲染未返回前图形承载框保持原尺寸', async () => {
    await act(async () => {
      root.render(
        <TooltipProvider>
          <CanvasStage />
        </TooltipProvider>,
      )
    })

    const sheet = container.querySelector<HTMLElement>('[data-page-sheet]')!
    const grid = sheet.firstElementChild as HTMLElement
    const world = container.querySelector<HTMLElement>('[data-world-transform]')!
    const object = container.querySelector<HTMLElement>('[data-object-id="p1"]')!
    const oldBox = { width: object.style.width, height: object.style.height }
    const oldGridSize = grid.style.backgroundSize
    expect(sheet.style.width).toBe(`${mmToWorld(100)}px`)
    expect(sheet.style.height).toBe(`${mmToWorld(80)}px`)

    act(() => setPageSize(120, 120))

    expect(sheet.style.width).toBe(`${mmToWorld(120)}px`)
    expect(sheet.style.height).toBe(`${mmToWorld(120)}px`)
    expect(world.style.width).toBe(`${mmToWorld(120)}px`)
    expect(world.style.height).toBe(`${mmToWorld(120)}px`)
    expect(grid.style.backgroundSize).toBe(oldGridSize)
    expect(object.style.width).toBe(oldBox.width)
    expect(object.style.height).toBe(oldBox.height)
  })
})
