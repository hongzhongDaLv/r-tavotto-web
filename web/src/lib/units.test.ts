import { describe, expect, it } from 'vitest'
import { editorPxToMm, formatEditorPx, mmToEditorPx } from './units'

describe('editor CSS px conversion', () => {
  it('converts at 96 CSS px per inch and round-trips document millimetres', () => {
    expect(mmToEditorPx(25.4)).toBe(96)
    expect(editorPxToMm(96)).toBe(25.4)
    expect(editorPxToMm(mmToEditorPx(120))).toBeCloseTo(120, 12)
  })

  it('formats document geometry as px for editor readouts', () => {
    expect(formatEditorPx(25.4)).toBe('96.0')
  })
})
