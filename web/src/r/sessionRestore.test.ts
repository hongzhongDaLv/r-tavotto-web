import { describe, expect, it, vi } from 'vitest'
import { restoreRSession } from './sessionRestore'

describe('restoreRSession', () => {
  it('restores the active local figure in a fresh browser tab', async () => {
    const request = vi.fn<typeof fetch>().mockResolvedValue(
      Response.json({ session_id: 'active-session', script: 'figure.R' }),
    )

    await expect(restoreRSession(null, request)).resolves.toMatchObject({ session_id: 'active-session' })
    expect(request).toHaveBeenCalledExactlyOnceWith('/r-api/state')
  })

  it('uses the tab session first and falls back to the active session if that id expired', async () => {
    const request = vi.fn<typeof fetch>()
      .mockResolvedValueOnce(new Response(null, { status: 400 }))
      .mockResolvedValueOnce(Response.json({ session_id: 'current-session' }))

    await expect(restoreRSession('stale/session', request)).resolves.toMatchObject({ session_id: 'current-session' })
    expect(request.mock.calls.map(([url]) => url)).toEqual([
      '/r-api/state?session_id=stale%2Fsession',
      '/r-api/state',
    ])
  })

  it('returns null when the service has no open figure', async () => {
    const request = vi.fn<typeof fetch>().mockResolvedValue(Response.json({}))

    await expect(restoreRSession(null, request)).resolves.toBeNull()
  })

  it('surfaces why a saved session could not be restored', async () => {
    const request = vi.fn<typeof fetch>().mockResolvedValue(
      Response.json({ restore_error: 'Source script changed since saving.' }),
    )

    await expect(restoreRSession(null, request)).rejects.toThrow('Source script changed since saving.')
  })
})
