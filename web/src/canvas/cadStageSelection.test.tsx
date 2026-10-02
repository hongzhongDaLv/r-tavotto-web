import { act } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { TooltipProvider } from '@/components/ui/Tooltip'
import { literal } from '@/i18n'
import type { Manifest, ManifestElement } from '@/lib/api'
import { useDocumentStore } from '@/store/documentStore'
import { useInteractionStore } from '@/store/interactionStore'
import { useRenderStore } from '@/store/renderStore'
import { useSelectionStore } from '@/store/selectionStore'
import { useUiStore } from '@/store/uiStore'
import { mmToWorld, useViewportStore } from '@/store/viewportStore'
import { useWorkspaceStore } from '@/store/workspace'
import { seedExactRender } from '@/test/renderFixtures'
import nativeScene from '@/test/fixtures/nativeMarquee.json'
import { emptyProject, type PanelObject } from '@/types/document'
import { CanvasStage } from './CanvasStage'
import { clientToPanelFraction } from './interactions'

globalThis.IS_REACT_ACT_ENVIRONMENT = true

class NoopResizeObserver {
  observe() {}
  disconnect() {}
  unobserve() {}
}
globalThis.ResizeObserver = NoopResizeObserver as unknown as typeof ResizeObserver

const panel: PanelObject = {
  id: 'r1', type: 'panel', fileId: 'r.pdf', fileKind: 'pdf',
  x: 20, y: 15, w: 100, h: 80, nativeW: 100, nativeH: 80,
  script: 'figure.R', overrides: [],
}
const element = (gid: string, bbox: number[], patch: Partial<ManifestElement> = {}) => ({
  gid, role: 'bar', label: gid, bbox, editable: [], draggable: false,
  canvas_selectable: true, r_native: true, ...patch,
}) as unknown as ManifestElement

// Both objects cross the same rectangle. Only the first is wholly inside it;
// a right-to-left crossing must also collect the second one's actual ink.
const scene: Manifest = {
  stem: 'R-fixture', size_mm: [100, 80],
  elements: [
    element('figure', [0, 0, 1, 1], { role: 'figure', canvas_selectable: false }),
    element('axes_0', [0.1, 0.1, 0.8, 0.8], { role: 'axes' }),
    element('layer-1', [0.1, 0.1, 0.8, 0.8], { canvas_selectable: false }),
    element('bar-inside', [0.1, 0.2, 0.2, 0.1]),
    element('bar-partial', [0.35, 0.2, 0.2, 0.1]),
    element('outside-page', [-0.35, 0.65, 0.1, 0.1], { role: 'text' }),
    element('errorbar', [0.1, 0.48, 0.5, 0.01], {
      role: 'line', geometry: { kind: 'polyline', fill: false, stroke: true,
        paths: [{ points: [[0.1, 0.485], [0.6, 0.485]], closed: false }] },
    }),
    element('diagonal', [0.05, 0.1, 0.5, 0.6], {
      role: 'line', geometry: { kind: 'polyline', fill: false, stroke: true,
        paths: [{ points: [[0.05, 0.1], [0.55, 0.7]], closed: false }] },
    }),
    element('hidden', [0.12, 0.22, 0.05, 0.05], {
      editable: [{ prop: 'visible', type: 'bool', value: false }] as never,
    }),
    element('locked', [0.12, 0.22, 0.05, 0.05]),
  ],
}

let container: HTMLDivElement
let root: Root
const stage = () => container.querySelector('[data-canvas-stage]') as HTMLDivElement
const livePanel = () => useDocumentStore.getState().doc.objects[0] as PanelObject
const selected = () => useUiStore.getState().selectedGids
const clientAt = ([fx, fy]: [number, number]) => ({
  clientX: mmToWorld(panel.x + panel.w * fx),
  clientY: mmToWorld(panel.y + panel.h * fy),
})

async function mount(manifest = scene) {
  seedExactRender(livePanel(), manifest)
  await act(async () => root.render(<TooltipProvider><CanvasStage /></TooltipProvider>))
  // jsdom cannot measure layout: fix only the viewport. Selection itself uses
  // the real stage handler and the exact render fixture, with no pick mocks.
  await act(async () => useViewportStore.setState({
    zoom: 1, panX: 0, panY: 0, originX: 0, originY: 0, viewW: 1000, viewH: 800,
  }))
}

async function begin(from: [number, number], init: MouseEventInit = {}) {
  const event = new MouseEvent('pointerdown', {
    button: 0, bubbles: true, cancelable: true, ...clientAt(from), ...init,
  })
  Object.assign(event, { pointerType: 'mouse', pointerId: 1 })
  await act(async () => stage().dispatchEvent(event))
}
async function move(to: [number, number]) {
  await act(async () => window.dispatchEvent(new MouseEvent('pointermove', { ...clientAt(to) })))
}
async function finish(to: [number, number], cancel = false) {
  await act(async () => window.dispatchEvent(new MouseEvent(cancel ? 'pointercancel' : 'pointerup', {
    ...clientAt(to),
  })))
}
async function drag(from: [number, number], to: [number, number], init: MouseEventInit = {}) {
  await begin(from, init)
  await move(to)
  const mode = container.querySelector('[data-overlay-svg] [data-marquee-mode]')?.getAttribute('data-marquee-mode')
  await finish(to)
  return mode
}

beforeEach(async () => {
  vi.stubGlobal('fetch', vi.fn(async () => new Response('{}', { status: 200 })))
  URL.createObjectURL = vi.fn(() => 'blob:fixture')
  localStorage.clear()
  useWorkspaceStore.getState().clear()
  useInteractionStore.getState().end()
  useSelectionStore.getState().clear()
  useRenderStore.getState().clear()
  useRenderStore.setState({ render: async () => {} })
  await useDocumentStore.getState().switchDocument(emptyProject(), 'd_r_cad')
  useDocumentStore.getState().commit(literal('add fixture'), (d) => {
    d.page.w = 100; d.page.h = 80
    d.objects.push({ ...panel, lockedGids: ['locked'] })
  })
  useDocumentStore.setState({ past: [], future: [] })
  useUiStore.setState({ tool: 'select', elementPanelId: panel.id, selectedGids: [],
    cropTargetId: null, showRulers: false, status: null })
  container = document.createElement('div')
  document.body.appendChild(container)
  root = createRoot(container)
})
afterEach(async () => {
  await act(async () => root.unmount())
  container.remove()
  vi.unstubAllGlobals()
})

describe('CAD from the real stage grey workspace', () => {
  it('left to right contains leaves; right to left intersects ink, never carrier or axes', async () => {
    await mount()
    const before = JSON.stringify(useDocumentStore.getState().doc)
    // x=-.25 is genuinely left of the page, not just a blank inside the SVG.
    expect(await drag([-.25, .15], [.45, .35])).toBe('window')
    expect(selected()).toEqual(['bar-inside'])
    expect(await drag([1.25, .35], [-.25, .15])).toBe('crossing')
    expect(selected()).toEqual(['bar-inside', 'bar-partial', 'diagonal'])
    expect(useSelectionStore.getState().ids).toEqual([])
    expect(JSON.stringify(useDocumentStore.getState().doc)).toBe(before)
    expect(useDocumentStore.getState().past).toEqual([])
  })

  it('selects out-of-page leaves and retains their physical coordinates', async () => {
    await mount()
    expect(await drag([-.5, .6], [-.2, .8])).toBe('window')
    expect(selected()).toEqual(['outside-page'])
    const bounds = container.querySelector('[data-overflow-hit-area]') as HTMLElement
    expect(bounds.style.left).toBe(`${-.35 * mmToWorld(100)}px`)
    expect(container.querySelector('[data-native-overflow="visible"]')).not.toBeNull()
    expect(container.querySelector('[data-editing-panel-outline]')).toBeNull()
  })

  it('uses exact errorbar paths and rejects a diagonal bbox empty corner', async () => {
    await mount()
    expect(await drag([1.25, .51], [.5, .46])).toBe('crossing')
    expect(selected()).toEqual(['errorbar'])
    expect(await drag([1.25, .18], [.5, .12])).toBe('crossing')
    expect(selected()).toEqual([])
  })

  it('Shift joins leaves; cancellation restores the prior selection', async () => {
    await mount()
    await act(async () => useUiStore.getState().setSelectedGid('outside-page'))
    await drag([-.25, .15], [.45, .35], { shiftKey: true })
    expect(selected()).toEqual(['outside-page', 'bar-inside'])
    await begin([1.25, .51])
    await move([.5, .46])
    expect(selected()).toEqual(['errorbar'])
    await finish([.5, .46], true)
    expect(selected()).toEqual(['outside-page', 'bar-inside'])
  })

  it('stale geometry cannot turn an exterior drag into a carrier selection', async () => {
    await mount()
    await act(async () => {
      useUiStore.getState().setSelectedGid('outside-page')
      useRenderStore.getState().markStale([panel.fileId])
    })
    await drag([-.25, .15], [.45, .35])
    expect(selected()).toEqual(['outside-page'])
    expect(useSelectionStore.getState().ids).toEqual([])
    expect(useInteractionStore.getState().kind).toBe('none')
  })

  it('an authority change during the gesture restores the original selection', async () => {
    await mount()
    await act(async () => useUiStore.getState().setSelectedGid('outside-page'))
    await begin([-.25, .15])
    await move([.45, .35])
    expect(selected()).toEqual(['bar-inside'])
    await act(async () => useRenderStore.getState().markStale([panel.fileId]))
    await finish([.45, .35])
    expect(selected()).toEqual(['outside-page'])
  })

  it('mounted stage consumes actual R-generated bars, point groups and individual errors', async () => {
    const real = nativeScene as unknown as Manifest
    await mount(real)
    const leaves = real.elements.filter((e) => e.canvas_selectable && e.gid !== 'figure' && e.role !== 'axes')
    expect(leaves.some((e) => e.gid.startsWith('errorbar-group-'))).toBe(true)
    expect(leaves.some((e) => e.gid.startsWith('point-group-'))).toBe(true)
    expect(leaves.some((e) => e.gid.startsWith('fill-group-'))).toBe(true)
    await drag([-.3, -.2], [1.3, 1.2])
    expect(selected()).toEqual(leaves.map((e) => e.gid))
    expect(selected().some((gid) => gid.startsWith('layer-'))).toBe(false)
  })
})

describe('exterior coordinate conversion', () => {
  it('accounts for viewport zoom/pan, quarter turns, flips and crop without clamping', () => {
    useViewportStore.setState({ zoom: 2, panX: 30, panY: -10, originX: 100, originY: 50 })
    const p: PanelObject = { ...panel, rotation: 90, flipH: true, crop: { x: .2, y: .1, w: .5, h: .8 } }
    const physical = { x: p.x + p.w / 2 + p.w * .25, y: p.y + p.h / 2 + p.h * .75 }
    const result = clientToPanelFraction(p, {
      clientX: 130 + mmToWorld(physical.x) * 2,
      clientY: 40 + mmToWorld(physical.y) * 2,
    })
    expect(result.fx).toBeCloseTo(.2 + (-.75 + .5) * .5)
    expect(result.fy).toBeCloseTo(.1 + (-.25 + .5) * .8)
    expect(result.fx).toBeLessThan(p.crop!.x)
  })
})
