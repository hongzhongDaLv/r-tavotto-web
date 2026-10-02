import { defineConfig, mergeConfig } from 'vite'
import original from './vite.config.ts'

export default mergeConfig(original, defineConfig({
  base: process.env.BROWSER_BASE_PATH || './',
  build: {
    outDir: 'dist-browser',
    rollupOptions: { input: 'browser.html' },
  },
  server: { port: 8770 },
}))
