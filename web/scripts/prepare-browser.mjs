import { mkdir, copyFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
const webRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const target = path.join(webRoot, 'public', 'r');
await mkdir(target, {recursive: true});
for (const name of ['engine.R', 'visual-properties.R']) {
  await copyFile(path.join(webRoot, '..', 'r-adapter', name), path.join(target, name));
}
console.log('Shared R engine prepared for browser build.');
