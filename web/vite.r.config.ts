import {defineConfig,mergeConfig} from 'vite'
import original from './vite.config'
export default mergeConfig(original,defineConfig({build:{outDir:'dist-r',rollupOptions:{input:'r.html'}},server:{port:5174,proxy:{'/r-api':'http://127.0.0.1:8766','/download':'http://127.0.0.1:8766'}}}))
