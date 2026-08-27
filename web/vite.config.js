import { defineConfig, loadEnv } from "vite";

// In development the browser and the agent gateway are different origins, and
// the gateway sends no CORS headers. Proxying /api through the dev server
// keeps the browser same-origin, which is the same arrangement CloudFront
// provides in production - so the application code is identical in both.
export default defineConfig(({ mode, command }) => {
  const env = loadEnv(mode, process.cwd(), "VITE_");
  const gateway = env.VITE_AGENT_GATEWAY_URL;

  // Only the dev server needs this. A production build is served by CloudFront,
  // which routes /api itself, so warning during a build would send the reader
  // after a setting that changes nothing.
  if (!gateway && command === "serve") {
    console.warn(
      "\n  VITE_AGENT_GATEWAY_URL is not set. Run ./scripts/write-web-config.sh first.\n"
    );
  }

  return {
    server: {
      port: 5173,
      strictPort: true,
      proxy: gateway
        ? {
            "/api": {
              target: gateway,
              changeOrigin: true,
              secure: true,
            },
          }
        : undefined,
    },
    build: {
      outDir: "dist",
      sourcemap: false,
    },
  };
});
