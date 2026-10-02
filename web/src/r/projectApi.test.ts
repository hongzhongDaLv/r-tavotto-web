import { afterEach, describe, expect, it, vi } from 'vitest'

import { fetchProjectJson, ProjectNetworkError } from './projectApi'

afterEach(() => {
  vi.restoreAllMocks()
})

describe('fetchProjectJson', () => {
  it('retries transient browser network rejection and returns the recovered response', async () => {
    const fetcher = vi.fn<typeof fetch>()
      .mockRejectedValueOnce(new TypeError('Failed to fetch'))
      .mockResolvedValueOnce(new Response(JSON.stringify({ projects: [] }), { status: 200 }))
    vi.spyOn(window, 'setTimeout').mockImplementation((callback) => {
      if (typeof callback === 'function') callback()
      return 0 as unknown as ReturnType<typeof window.setTimeout>
    })

    await expect(fetchProjectJson<{ projects: unknown[] }>('/r-api/projects', fetcher))
      .resolves.toEqual({ projects: [] })
    expect(fetcher).toHaveBeenCalledTimes(2)
  })

  it('stops after three network failures and exposes a recoverable transport error', async () => {
    const fetcher = vi.fn<typeof fetch>().mockRejectedValue(new TypeError('Failed to fetch'))
    vi.spyOn(window, 'setTimeout').mockImplementation((callback) => {
      if (typeof callback === 'function') callback()
      return 0 as unknown as ReturnType<typeof window.setTimeout>
    })

    await expect(fetchProjectJson('/r-api/projects', fetcher)).rejects.toBeInstanceOf(ProjectNetworkError)
    expect(fetcher).toHaveBeenCalledTimes(3)
  })

  it('does not retry HTTP failures', async () => {
    const fetcher = vi.fn<typeof fetch>().mockResolvedValue(
      new Response(JSON.stringify({ error: 'Project folder is not configured.' }), { status: 400 }),
    )

    await expect(fetchProjectJson('/r-api/projects/bad/scripts', fetcher))
      .rejects.toThrow('Project folder is not configured.')
    expect(fetcher).toHaveBeenCalledTimes(1)
  })
})
