// Screenshots every scene in out/ with headless Chromium:
//   node tools/preview/render.mjs [scene ...] [--views iso,low]
// Writes out/<scene>-<view>.png. Set CHROMIUM_PATH to use a specific browser binary.

import { createServer } from "node:http";
import { readFile, readdir } from "node:fs/promises";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const root = fileURLToPath(new URL(".", import.meta.url));
const outDir = join(root, "out");
const args = process.argv.slice(2);
const viewsFlag = args.indexOf("--views");
const views = viewsFlag >= 0 ? args.splice(viewsFlag, 2)[1].split(",") : ["iso", "low"];
const scenes = args.length > 0 ? args : (await readdir(outDir)).filter((f) => f.endsWith(".json")).map((f) => f.slice(0, -5));

const TYPES = { ".html": "text/html", ".js": "text/javascript", ".json": "application/json" };
const server = createServer(async (req, res) => {
  const path = normalize(join(root, decodeURIComponent(new URL(req.url, "http://x").pathname)));
  if (!path.startsWith(root)) return res.writeHead(403).end();
  try {
    const body = await readFile(path);
    res.writeHead(200, { "content-type": TYPES[extname(path)] ?? "application/octet-stream" }).end(body);
  } catch {
    res.writeHead(404).end();
  }
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const base = `http://127.0.0.1:${server.address().port}`;

const browser = await chromium.launch({
  executablePath: process.env.CHROMIUM_PATH || undefined,
  args: ["--use-angle=swiftshader", "--enable-unsafe-swiftshader", "--ignore-gpu-blocklist"],
});
const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
page.on("pageerror", (error) => console.error(`page error: ${error.message}`));

for (const scene of scenes) {
  for (const view of views) {
    await page.goto(`${base}/viewer.html?scene=${encodeURIComponent(scene)}&view=${view}`);
    await page.waitForFunction(() => window.__rendered === true, null, { timeout: 120_000 });
    const file = join(outDir, `${scene}-${view}.png`);
    await page.screenshot({ path: file });
    console.log(`wrote ${file}`);
  }
}

await browser.close();
server.close();
