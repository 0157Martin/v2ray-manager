import { createHash } from 'node:crypto'
import { readdir, readFile, writeFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import { dirname, join, relative } from 'node:path'

const root = join(dirname(fileURLToPath(import.meta.url)), '..', 'dist')
async function files(path) {
  const entries = await readdir(path, { withFileTypes: true })
  const nested = await Promise.all(entries.filter((entry) => entry.name !== 'deploy-manifest.json').map(async (entry) => entry.isDirectory() ? files(join(path, entry.name)) : [join(path, entry.name)]))
  return nested.flat()
}
const paths = await files(root)
const entries = await Promise.all(paths.map(async (path) => ({ path: relative(root, path).replaceAll('\\', '/'), sha256: createHash('sha256').update(await readFile(path)).digest('hex') })))
await writeFile(join(root, 'deploy-manifest.json'), `${JSON.stringify({ version: 1, files: entries }, null, 2)}\n`)