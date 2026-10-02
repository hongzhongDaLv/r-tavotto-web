import type { ManifestElement } from './api'
import { segIntersectsRect } from './elementGeom'
import { geomHitsRect, type FracRect } from './pathGeom'

export type ElementMarqueeMode = 'window' | 'crossing'

/** The CAD convention follows the drag direction on screen, including rotated plots. */
export function elementMarqueeModeForDrag(startClientX: number, endClientX: number): ElementMarqueeMode {
  return endClientX >= startClientX ? 'window' : 'crossing'
}

function contains(outer: FracRect, inner: FracRect): boolean {
  return (
    inner.x >= outer.x &&
    inner.y >= outer.y &&
    inner.x + inner.w <= outer.x + outer.w &&
    inner.y + inner.h <= outer.y + outer.h
  )
}

function overlaps(a: FracRect, b: FracRect): boolean {
  return a.x < b.x + b.w && a.x + a.w > b.x && a.y < b.y + b.h && a.y + a.h > b.y
}

/**
 * CAD-style canvas marquee semantics: left-to-right is a window (whole object
 * inside); right-to-left is crossing (any visible geometry touched). Structural
 * axes frames are selected from the object tree and never enter canvas marquees.
 * Tree-only semantic groups do not participate in canvas marquees.
 */
export function elementMarqueeHit(
  el: ManifestElement,
  rect: FracRect,
  mode: ElementMarqueeMode,
): boolean {
  if (el.gid === 'figure' || el.canvas_selectable === false) return false
  if (el.role === 'axes' || el.role === 'axes3d') return false

  const [x, y, w, h] = el.bbox
  const box = { x, y, w, h }
  if (mode === 'window') return contains(rect, box)
  if (el.arrow_endpoints && el.arrow_endpoints.length >= 2) {
    return segIntersectsRect(el.arrow_endpoints[0], el.arrow_endpoints[1], rect)
  }
  if (el.geometry) return geomHitsRect(el.geometry, rect)
  return overlaps(box, rect)
}
