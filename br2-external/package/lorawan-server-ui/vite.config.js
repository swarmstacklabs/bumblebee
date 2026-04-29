import { defineConfig } from 'vite';
import vue from '@vitejs/plugin-vue';

const outDir = process.env.BUILD_OUT_DIR || 'dist';
const devPort = Number(
  process.env.LORAWAN_SERVER_UI_DEV_PORT || process.env.BUMBLEBEE_FRONTEND_DEV_PORT || 5173
);
const apiOrigin =
  process.env.LORAWAN_SERVER_API_ORIGIN ||
  `http://127.0.0.1:${process.env.LORAWAN_SERVER_HTTP_PORT || 8080}`;

export default defineConfig({
  plugins: [vue()],
  server: {
    host: true,
    port: devPort,
    strictPort: true,
    hmr: {
      clientPort: devPort
    },
    proxy: {
      '/api': {
        target: apiOrigin,
        changeOrigin: true
      },
      '/admin/timeline': {
        target: apiOrigin,
        changeOrigin: true
      }
    }
  },
  build: {
    outDir
  }
});
