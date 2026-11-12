import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

export default defineConfig({
  plugins: [vue()],
  build: { target: 'es2022' },
  server: {
    // During development proxy the node HTTP API (bootstrap list, ICE, region).
    proxy: { '/api': process.env.NODE_HTTP ?? 'http://127.0.0.1:8003' }
  }
})
