import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";

export default defineConfig({
  base: "./",
  plugins: [
    react(),
    {
      // React Refresh requires an inline preamble in the local development server.
      // Production retains the strict CSP declared in index.html.
      name: "dev-csp",
      apply: "serve",
      transformIndexHtml: (html) =>
        html.replace(/<meta\s+http-equiv="Content-Security-Policy"[^>]*>/, ""),
    },
    {
      // Native result panels load from file: under WKWebView. A single classic
      // script works in both WKWebView and Tauri without file-origin ESM access.
      name: "native-classic-script",
      apply: "build",
      transformIndexHtml: {
        order: "post",
        handler: (html) =>
          html
            .replace(/<script type="module" crossorigin/g, "<script defer")
            .replace(/<link rel="modulepreload"[^>]*>/g, "")
            .replace(
              /<link rel="stylesheet" crossorigin/g,
              '<link rel="stylesheet"',
            ),
      },
    },
  ],
  server: { host: "127.0.0.1", port: 1420, strictPort: true },
  build: {
    outDir: "dist-web",
    emptyOutDir: true,
    target: "safari14",
    rolldownOptions: { output: { format: "iife", codeSplitting: false } },
  },
  test: { include: ["tests/frontend/**/*.test.ts"], environment: "node" },
});
