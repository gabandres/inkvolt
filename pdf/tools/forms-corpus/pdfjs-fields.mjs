#!/usr/bin/env node
// The form fields pdf.js (Mozilla's viewer) sees in PDFs, as the independent reader of tools/forms-corpus: for each file,
// one JSON line { file, widgets: [{ page, name, type, value, hasAppearance, checkBox, radioButton, buttonValue,
// exportValue, readOnly, hidden }] } or { file, error }.
// Uses pdfjs-dist from ../pdfjs-check (run `npm ci` there once). Usage: node pdfjs-fields.mjs a.pdf [b.pdf ...]
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const require = createRequire(join(here, "..", "pdfjs-check", "index.mjs"));
const pdfjsDir = dirname(require.resolve("pdfjs-dist/package.json"));
const { getDocument } = await import(pathToFileURL(join(pdfjsDir, "legacy", "build", "pdf.mjs")).href);

const timeout = (ms) => new Promise((_, reject) => setTimeout(() => reject(new Error(`pdf.js took over ${ms} ms`)), ms).unref());

async function read(file) {
  const data = new Uint8Array(readFileSync(file));
  const task = getDocument({
    data,
    standardFontDataUrl: join(pdfjsDir, "standard_fonts") + "/",
    cMapUrl: join(pdfjsDir, "cmaps") + "/",
    cMapPacked: true,
    verbosity: 0,
    enableXfa: false,
  });
  try {
    const doc = await task.promise;
    const widgets = [];
    for (let p = 1; p <= doc.numPages; p++) {
      const page = await doc.getPage(p);
      for (const a of await page.getAnnotations({ intent: "display" })) {
        if (a.subtype !== "Widget") continue;
        widgets.push({
          page: p, name: a.fieldName, type: a.fieldType, value: a.fieldValue, hasAppearance: a.hasAppearance,
          checkBox: a.checkBox, radioButton: a.radioButton, pushButton: a.pushButton, buttonValue: a.buttonValue,
          exportValue: a.exportValue, readOnly: a.readOnly, hidden: a.hidden, textContent: a.textContent ? a.textContent.join(" ") : undefined,
        });
      }
      page.cleanup();
    }
    return { file, widgets };
  } finally {
    await task.destroy();
  }
}

for (const arg of process.argv.slice(2)) {
  const file = resolve(arg);
  let result;
  try {
    result = await Promise.race([read(file), timeout(60000)]);
  } catch (e) {
    result = { file, error: String(e?.message ?? e).slice(0, 300) };
  }
  // Waits for the write: a pipe on macOS takes 64 KB at a time, and process.exit would cut a long line off.
  await new Promise((done) => process.stdout.write(JSON.stringify(result) + "\n", done));
}
process.exit(0);
