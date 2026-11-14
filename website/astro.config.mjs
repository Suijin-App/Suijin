import { defineConfig } from "astro/config";
import sitemap from "@astrojs/sitemap";

// A fully static site: every page is plain HTML at build time, which is what search engines and AI assistants read
// best. The Worker in worker/index.js serves these files and the app's update feed.
export default defineConfig({
  site: "https://suijin.app",
  output: "static",
  trailingSlash: "never",
  build: { format: "file" },
  // Keep the spaces between words and inline elements that sit on separate lines of a template.
  compressHTML: false,
  integrations: [sitemap({ lastmod: new Date() })],
  // Screenshots are imported from docs/screenshots at the repository root, so the site and the README share them.
  vite: { server: { fs: { allow: [".."] } } },
});
