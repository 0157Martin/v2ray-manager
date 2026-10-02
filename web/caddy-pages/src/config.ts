export type PageConfig = { template: 'portfolio' | 'resume'; domain: string; seed: string }

const fallback: PageConfig = { template: 'portfolio', domain: 'example.com', seed: 'preview' }

export async function loadConfig(): Promise<PageConfig> {
  try {
    const response = await fetch('./site-config.json', { cache: 'no-store' })
    if (!response.ok) return fallback
    const candidate = await response.json() as Partial<PageConfig>
    if ((candidate.template !== 'portfolio' && candidate.template !== 'resume') || typeof candidate.domain !== 'string') return fallback
    return { template: candidate.template, domain: candidate.domain, seed: typeof candidate.seed === 'string' ? candidate.seed : 'preview' }
  } catch { return fallback }
}

function hash(value: string) { return [...value].reduce((total, char) => ((total << 5) - total + char.charCodeAt(0)) | 0, 0) >>> 0 }
export function choose<T>(items: readonly T[], seed: string, salt: string): T { return items[hash(`${seed}:${salt}`) % items.length] }