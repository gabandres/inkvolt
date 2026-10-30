#!/usr/bin/env node
// Prints the text pdf.js reads from a PDF, page by page, in the order it reads it (one JSON object on stdout:
// { pages: [{ page: 1, text: "..." }, ...] }), so a test can tell whether an edited PDF reads the same in pdf.js as
// in MuPDF. Usage: node index.mjs file.pdf [first-page [last-page]]  (pages are 1-based, inclusive).
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { getDocument } from "pdfjs-dist/legacy/build/pdf.mjs";

const pdfjsDir = dirname(createRequire(import.meta.url).resolve("pdfjs-dist/package.json"));

const [file, firstArg, lastArg] = process.argv.slice(2);
if (!file) {
  console.error("usage: node index.mjs file.pdf [first-page [last-page]]");
  process.exit(2);
}

const data = new Uint8Array(readFileSync(file));
const task = getDocument({
  data,
  standardFontDataUrl: join(pdfjsDir, "standard_fonts") + "/",
  cMapUrl: join(pdfjsDir, "cmaps") + "/",
  cMapPacked: true,
  verbosity: 0,
});
const doc = await task.promise;

const first = Math.max(1, Number(firstArg ?? 1));
const last = Math.min(doc.numPages, Number(lastArg ?? firstArg ?? doc.numPages));
const pages = [];
for (let n = first; n <= last; n++) {
  const page = await doc.getPage(n);
  const content = await page.getTextContent();
  let text = "";
  for (const item of content.items) {
    if (!("str" in item)) continue;
    text += item.str;
    if (item.hasEOL) text += "\n";
  }
  pages.push({ page: n, text });
  page.cleanup();
}
const numPages = doc.numPages;
await task.destroy();
process.stdout.write(JSON.stringify({ file, numPages, pages }) + "\n");
