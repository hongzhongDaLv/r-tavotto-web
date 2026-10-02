import { beforeEach, describe, expect, it, vi } from 'vitest'

import { literal } from '@/i18n'
import type { Manifest, ManifestElement } from '@/lib/api'
import { emptyProject, type PanelObject } from '@/types/document'
import { useDocumentStore } from '@/store/documentStore'
import { useInteractionStore } from '@/store/interactionStore'
import { setOverride, setPageSize } from '@/store/actions'
import { exactPanelManifest, useRenderStore } from '@/store/renderStore'
import { seedExactRender } from '@/test/renderFixtures'
import { mmToWorld, useViewportStore } from '@/store/viewportStore'
import { startAxesDrag, startFigureSizeDrag, resizeFigureMm } from './interactions'

vi.mock('@/store/renderScheduler', () => ({ requestRender: vi.fn() }))

const figure: ManifestElement = {
  gid: 'figure',
  role: 'figure',
  label: 'Figure',
  bbox: [0, 0, 1, 1],
  editable: [{ prop: 'size_mm', type: 'pair', value: [100, 80], unit: 'mm' }],
  draggable: false,
  resizable: true,
  canvas_selectable: false,
  r_native: true,
}
const axes: ManifestElement = {
  gid: 'axes_0',
  role: 'axes',
  label: 'Plot frame',
  bbox: [0.2, 0.2, 0.6, 0.5],
  editable: [{ prop: 'frame_mm', type: 'rect', value: [20, 16, 60, 40], unit: 'mm' }],
  draggable: false,
  resizable: true,
  r_native: true,
}
const manifest: Manifest = { stem: 'R-figure', size_mm: [100, 80], elements: [figure, axes] }
const panel = (): PanelObject => ({
  id: 'p1', type: 'panel', x: 0, y: 0, w: 100, h: 80,
  fileId: 'R-figure.pdf', fileKind: 'pdf', nativeW: 100, nativeH: 80,
  script: 'project.R', overrides: [],
})
const sizeMm: [number, number] = [100, 80]
const layout = { width: mmToWorld(100), height: mmToWorld(80) }
const down = (clientX = 0, clientY = 0) =>
  ({ clientX, clientY, button: 0, stopPropagation() {} }) as unknown as React.PointerEvent
const fire = (type: 'pointermove' | 'pointerup' | 'pointercancel', clientX: number, clientY: number) =>
  window.dispatchEvent(new MouseEvent(type, { clientX, clientY, bubbles: true }))

async function setup() {
  useViewportStore.setState({ zoom: 1, panX: 0, panY: 0, originX: 0, originY: 0 })
  useInteractionStore.getState().end()
  await useDocumentStore.getState().switchDocument(emptyProject(), 'd_figure_size')
  useDocumentStore.getState().commit(literal('Add panel'), (d) => {
    d.page.w = 100
    d.page.h = 80
    d.objects.push(panel())
  })
  seedExactRender(panel(), manifest)
  useDocumentStore.setState({ past: [], future: [] })
}

describe('R Figure canvas size', () => {
  beforeEach(setup)

  it('an ordinary multi-object workspace page remains independent from its embedded R figure', () => {
    useDocumentStore.getState().commit(literal('Add another object'), (d) => {
      d.objects.push({ ...panel(), id: 'p2', x: 120 })
    })
    const beforePage = useDocumentStore.getState().doc.page
    const before = useDocumentStore.getState().doc.objects[0] as PanelObject
    setPageSize(250, 170)

    const after = useDocumentStore.getState().doc.objects[0] as PanelObject
    expect(useDocumentStore.getState().doc.page).toMatchObject({ w: 250, h: 170 })
    expect(after.overrides).toEqual(before.overrides)
    expect([after.x, after.y, after.w, after.h]).toEqual([before.x, before.y, before.w, before.h])
    expect([after.nativeW, after.nativeH]).toEqual([before.nativeW, before.nativeH])
    expect(beforePage).not.toMatchObject({ w: 250, h: 170 })
  })

  it('Canvas page size edits update the R output and page but do not resize a stale figure preview', () => {
    const original = useDocumentStore.getState().doc.objects[0] as PanelObject
    const originalManifest = exactPanelManifest(useRenderStore.getState(), original)!
    const originalFrame = originalManifest.elements
      .find((element) => element.gid === 'axes_0')!
      .editable.find((field) => field.prop === 'frame_mm')!.value

    // Width and height are separate UI commits. The second edit happens while
    // the first variant is still rendering, so native adapter identity must be
    // recognized through the latest successful manifest.
    setPageSize(120, 80)
    setPageSize(120, 120)

    const saved = useDocumentStore.getState().doc.objects[0] as PanelObject
    expect(useDocumentStore.getState().doc.page).toMatchObject({ w: 120, h: 120 })
    // Keep the last rendered image at its real aspect until the matching SVG arrives.
    expect([saved.w, saved.h]).toEqual([100, 80])
    expect(saved.overrides).toEqual([{ gid: 'figure', prop: 'size_mm', value: [120, 120] }])

    // A worker response for the new variant updates the manifest; its R page
    // size agrees with both host representations while the axes remain in mm.
    const rerenderedManifest: Manifest = { ...manifest, size_mm: [120, 120] }
    seedExactRender(saved, rerenderedManifest)
    const rendered = exactPanelManifest(useRenderStore.getState(), saved)!
    expect(rendered.size_mm).toEqual([120, 120])
    expect(
      rendered.elements.find((element) => element.gid === 'axes_0')!
        .editable.find((field) => field.prop === 'frame_mm')!.value,
    ).toEqual(originalFrame)
  })

  it('resizing the R output immediately changes the page but leaves the old panel box undistorted', () => {
    setOverride('p1', 'figure', 'size_mm', [120, 60], true)

    const saved = useDocumentStore.getState().doc.objects[0] as PanelObject
    expect(useDocumentStore.getState().doc.page).toMatchObject({ w: 120, h: 60 })
    expect(saved.overrides.find((p) => p.gid === 'figure' && p.prop === 'size_mm')?.value).toEqual([120, 60])
    expect(saved.overrides).toEqual([{ gid: 'figure', prop: 'size_mm', value: [120, 60] }])
    expect([saved.w, saved.h]).toEqual([100, 80])
    expect(useDocumentStore.getState().past).toHaveLength(1)

    useDocumentStore.getState().undo()
    const restored = useDocumentStore.getState().doc.objects[0] as PanelObject
    expect(restored.overrides).toEqual([])
    expect([restored.w, restored.h]).toEqual([100, 80])
  })

  it('dragging the Figure page handle commits output size without stretching the old preview', () => {
    startFigureSizeDrag(down(), panel(), figure, sizeMm, layout, 'se')
    fire('pointermove', layout.width / 10, layout.height / 10)

    expect(useInteractionStore.getState().elementPreview?.boxes.figure).toEqual([0, 0, 1.1, 1.1])
    fire('pointerup', layout.width / 10, layout.height / 10)

    const saved = useDocumentStore.getState().doc.objects[0] as PanelObject
    expect(useDocumentStore.getState().doc.page).toMatchObject({ w: 110, h: 88 })
    expect(saved.overrides.find((p) => p.gid === 'figure' && p.prop === 'size_mm')?.value).toEqual([110, 88])
    expect(saved.overrides).toEqual([{ gid: 'figure', prop: 'size_mm', value: [110, 88] }])
    expect([saved.w, saved.h]).toEqual([100, 80])
    expect(useDocumentStore.getState().past).toHaveLength(1)
    expect(useInteractionStore.getState().elementPreview).toBeNull()

    useDocumentStore.getState().undo()
    const restored = useDocumentStore.getState().doc.objects[0] as PanelObject
    expect(useDocumentStore.getState().doc.page).toMatchObject({ w: 100, h: 80 })
    expect(restored.overrides).toEqual([])
    expect([restored.w, restored.h]).toEqual([100, 80])
  })

  it('moving an R axes frame writes only physical frame_mm and translates the rendered page', () => {
    startAxesDrag(down(), panel(), axes, layout, 'move')
    fire('pointermove', layout.width / 10, layout.height / 10)

    expect(useInteractionStore.getState().elementPreview?.boxes.axes_0).toEqual([0.3, 0.3, 0.6, 0.5])
    fire('pointerup', layout.width / 10, layout.height / 10)

    const saved = useDocumentStore.getState().doc.objects[0] as PanelObject
    expect(saved.overrides).toEqual([{ gid: 'axes_0', prop: 'frame_mm', value: [30, 24, 60, 40] }])
    expect(saved.overrides.some((patch) => patch.gid === 'axes_0' && patch.prop === 'position')).toBe(false)
    expect([saved.w, saved.h]).toEqual([100, 80])
  })

  it('resizing an R axes frame changes only the data area and allows page overflow', () => {
    startAxesDrag(down(), panel(), axes, layout, 'e')
    fire('pointermove', layout.width, 0)

    expect(useInteractionStore.getState().elementPreview?.boxes.axes_0).toEqual([0.2, 0.2, 1.6, 0.5])
    fire('pointerup', layout.width, 0)
    let saved = useDocumentStore.getState().doc.objects[0] as PanelObject
    expect(saved.overrides).toEqual([{ gid: 'axes_0', prop: 'frame_mm', value: [20, 16, 160, 40] }])

    useDocumentStore.getState().undo()
    startAxesDrag(down(), panel(), axes, layout, 'w')
    fire('pointermove', -layout.width, 0)
    fire('pointerup', -layout.width, 0)
    saved = useDocumentStore.getState().doc.objects[0] as PanelObject
    const frame = saved.overrides.find((patch) => patch.gid === 'axes_0' && patch.prop === 'frame_mm')?.value as number[]
    expect(frame[0]).toBeLessThan(0)
    expect(frame[2]).toBeGreaterThan(0)
    expect(frame[0] + frame[2]).toBeCloseTo(80)
  })

  it('pointer cancellation rolls back an R axes frame preview without writing an override', () => {
    startAxesDrag(down(), panel(), axes, layout, 'move')
    fire('pointermove', layout.width / 10, layout.height / 10)
    fire('pointercancel', layout.width / 10, layout.height / 10)

    const saved = useDocumentStore.getState().doc.objects[0] as PanelObject
    expect(saved.overrides).toEqual([])
    expect(useInteractionStore.getState().elementPreview).toBeNull()
  })

  it('keeps an outer layout page independent when the R Figure is one of several objects', () => {
    useDocumentStore.getState().commit(literal('Add another object'), (d) => {
      d.objects.push({ ...panel(), id: 'p2', x: 120 })
    })
    const pageBefore = { ...useDocumentStore.getState().doc.page }

    setOverride('p1', 'figure', 'size_mm', [120, 60], true)

    expect(useDocumentStore.getState().doc.page).toEqual(pageBefore)
  })

  it('pointer cancellation leaves output and page geometry untouched', () => {
    startFigureSizeDrag(down(), panel(), figure, sizeMm, layout, 'e')
    fire('pointermove', layout.width / 4, 0)
    fire('pointercancel', layout.width / 4, 0)

    const saved = useDocumentStore.getState().doc.objects[0] as PanelObject
    expect(saved.overrides).toEqual([])
    expect([saved.w, saved.h]).toEqual([100, 80])
    expect(useInteractionStore.getState().elementPreview).toBeNull()
  })
})

describe('resizeFigureMm', () => {
  it('changes only the edge-controlled dimension and clamps to R output limits', () => {
    expect(resizeFigureMm([100, 80], 'e', 0.1, 0.2)).toEqual([110, 80])
    expect(resizeFigureMm([100, 80], 's', 0.1, 0.1)).toEqual([100, 88])
    expect(resizeFigureMm([100, 80], 'se', 0.1, 0.1)).toEqual([110, 88])
    expect(resizeFigureMm([21, 399], 'se', -1, 1)).toEqual([20, 400])
  })
})
