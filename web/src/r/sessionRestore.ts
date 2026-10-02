export type RestorableRSession = { session_id?: string; restore_error?: string }

/** Restore the tab's session, or the local adapter's active session in a fresh tab. */
export async function restoreRSession<T extends RestorableRSession>(
  priorSessionId: string | null,
  request: typeof fetch = fetch,
): Promise<T | null> {
  const endpoints = priorSessionId
    ? ['/r-api/state?session_id=' + encodeURIComponent(priorSessionId), '/r-api/state']
    : ['/r-api/state']

  for (const endpoint of endpoints) {
    const response = await request(endpoint)
    if (!response.ok) continue
    const state = (await response.json()) as T
    if ('restore_error' in state && typeof state.restore_error === 'string') throw Error(state.restore_error)
    if (state.session_id) return state
  }
  return null
}
