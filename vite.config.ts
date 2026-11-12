import { defineConfig, loadEnv, type Plugin } from 'vite';
import react from '@vitejs/plugin-react';
import path from 'node:path';

// A14 · bundle: pages are lazy-loaded (src/App.tsx) and the PDF / Excel libraries load on demand. The rest of the
// start-up code is split into cacheable chunks so no single file is huge and a deploy that only changes one page
// does not invalidate the vendor or translation chunks.
const CHUNKS: Array<[RegExp, string]> = [
  [/node_modules\/(react|react-dom|scheduler|react-router|react-router-dom|@remix-run)\//, 'vendor-react'],
  [/node_modules\/@supabase\//, 'vendor-supabase'],
  [/node_modules\/(@tanstack|i18next|react-i18next)\//, 'vendor-app'],
  [/node_modules\/lucide-react\//, 'vendor-icons'],
  [/src\/lib\/i18n\/en\.json/, 'i18n-en'],
  [/src\/lib\/i18n\/ar\.json/, 'i18n-ar'],
  [/src\/features\/erp\/design-data\.json/, 'design-data'],
];

/**
 * A14 · CSP narrowed to this build's Supabase project. vercel.json sends a CSP header that allows any *.supabase.co
 * (Preview deployments point at a Supabase branch with its own address). This build-only meta tag adds a second policy
 * with the exact VITE_SUPABASE_URL; browsers enforce both, so the app can only talk to its own project.
 * Not used by the dev server (Vite's dev client needs inline scripts).
 */
function cspMeta(supabaseUrl: string | undefined): Plugin {
  return {
    name: 'csp-meta',
    apply: 'build',
    transformIndexHtml(html) {
      if (!supabaseUrl) return html;
      const u = new URL(supabaseUrl);
      const http = `${u.protocol}//${u.host}`;
      const ws = `${u.protocol === 'https:' ? 'wss:' : 'ws:'}//${u.host}`;
      const policy = `default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; font-src 'self' data:; ` +
        `img-src 'self' data: blob: ${http}; connect-src 'self' data: blob: ${http} ${ws}; worker-src 'self' blob:; media-src 'self' blob:; object-src 'none'; base-uri 'self'; form-action 'self'`;
      return html.replace('<meta charset="UTF-8" />', `<meta charset="UTF-8" />\n    <meta http-equiv="Content-Security-Policy" content="${policy}" />`);
    },
  };
}

export default defineConfig(({ mode }) => ({
  plugins: [react(), cspMeta(loadEnv(mode, process.cwd(), 'VITE_').VITE_SUPABASE_URL)],
  resolve: { alias: { '@': path.resolve(__dirname, 'src') } },
  server: { port: 5173 },
  build: {
    rollupOptions: {
      output: {
        manualChunks(id) {
          const n = id.replace(/\\/g, '/');
          return CHUNKS.find(([re]) => re.test(n))?.[1];
        },
      },
    },
  },
}));
