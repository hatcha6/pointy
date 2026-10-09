import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Built into the relay binary (go:embed) and served at /console/.
// `npm run dev` proxies the API to a local relay started with
// POINTY_RELAY_CONSOLE_ORIGIN=http://localhost:5173.
export default defineConfig({
  base: "/console/",
  plugins: [react()],
  build: {
    outDir: "../internal/console/dist",
    emptyOutDir: false,
    assetsInlineLimit: 0,
    sourcemap: false,
    target: "es2022",
  },
  server: {
    port: 5173,
    strictPort: true,
    proxy: {
      "/console/api": { target: "http://127.0.0.1:8091", changeOrigin: false },
    },
  },
});
