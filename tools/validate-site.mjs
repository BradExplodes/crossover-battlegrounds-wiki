import { existsSync, readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, "..");
const EXTERNAL_RE = /^(https?:|mailto:|tel:|#|data:|javascript:)/i;

function walk(dir, out = []) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (entry.name === ".git" || entry.name === "node_modules") continue;
      walk(full, out);
    } else if (entry.name.endsWith(".html")) {
      out.push(full);
    }
  }
  return out;
}

function resolveLocalUrl(fromFile, rawUrl) {
  const clean = rawUrl.split("#")[0].split("?")[0];
  if (!clean || EXTERNAL_RE.test(clean)) return null;

  let target = path.resolve(path.dirname(fromFile), clean);
  if (clean.endsWith("/") || !path.extname(target)) {
    target = path.join(target, "index.html");
  }
  return target;
}

const htmlFiles = walk(ROOT);
const missing = [];

for (const file of htmlFiles) {
  const html = readFileSync(file, "utf8");
  const urls = [...html.matchAll(/\b(?:href|src)="([^"]+)"/g)].map((match) => match[1]);
  for (const url of urls) {
    const target = resolveLocalUrl(file, url);
    if (target && !existsSync(target)) {
      missing.push(`${path.relative(ROOT, file)} -> ${url}`);
    }
  }
}

const data = JSON.parse(readFileSync(path.join(ROOT, "data", "wiki-data.json"), "utf8"));
const characterPages = htmlFiles.filter((file) => /[\\/]characters[\\/][^\\/]+[\\/]index\.html$/.test(file));

if (characterPages.length !== data.characters.length) {
  missing.push(`character page count ${characterPages.length} does not match data count ${data.characters.length}`);
}

if (missing.length) {
  console.error(missing.join("\n"));
  process.exit(1);
}

console.log(`Validated ${htmlFiles.length} HTML files and ${data.characters.length} character pages.`);
