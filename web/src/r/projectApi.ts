/** Read-only project browser requests. Writes stay on the regular transport. */
export class ProjectNetworkError extends Error {
  constructor(cause?: unknown) {
    super('Project browser could not reach the local Tavotto R service.', { cause })
    this.name = 'ProjectNetworkError'
  }
}

const RETRY_DELAYS_MS = [250, 800]

function isFetchNetworkError(error: unknown): error is TypeError {
  return error instanceof TypeError
}

function delay(ms: number) {
  return new Promise((resolve) => window.setTimeout(resolve, ms))
}

/** Retry only browser-level network rejection; never retry an HTTP error or mutation. */
export async function fetchProjectJson<T>(url: string, fetcher: typeof fetch = fetch): Promise<T> {
  let response: Response | undefined
  let lastError: unknown

  for (let attempt = 0; attempt <= RETRY_DELAYS_MS.length; attempt += 1) {
    try {
      response = await fetcher(url)
      break
    } catch (error) {
      if (!isFetchNetworkError(error)) throw error
      lastError = error
      if (attempt === RETRY_DELAYS_MS.length) throw new ProjectNetworkError(lastError)
      await delay(RETRY_DELAYS_MS[attempt])
    }
  }

  if (!response) throw new ProjectNetworkError(lastError)
  const data = (await response.json()) as T & { error?: string }
  if (!response.ok) throw Error(data.error || response.statusText)
  return data
}
