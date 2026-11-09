import { defineConfig } from "vite";

// Relative paths, so the build works from a domain root or from GitHub Pages' /wick/ alike.
export default defineConfig({
  base: "./",
  // The laptop is three.js, loaded on its own after the page has painted. That one chunk is expected to be large.
  build: { chunkSizeWarningLimit: 700 },
});
