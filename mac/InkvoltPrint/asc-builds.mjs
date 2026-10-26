// Lists Inkvolt Print's macOS builds in App Store Connect and their processing state, so an upload is checked where it
// lands (altool has reported success for builds that never arrived).
//   node mac/InkvoltPrint/asc-builds.mjs [build number] [--wait]
// --wait polls every 30 s (up to 30 min) until that build is VALID (exit 0), or INVALID/FAILED (exit 1).
// Uses the App Store Connect API key in .env.local (ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH). Node's own crypto only.
import { createSign } from "node:crypto";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const BUNDLE_ID = "com.bermudezsystems.InkvoltPrint";
const env = Object.fromEntries(
  readFileSync(join(dirname(fileURLToPath(import.meta.url)), ".env.local"), "utf8")
    .split("\n").map((l) => l.replace(/^export /, "").trim()).filter((l) => l && !l.startsWith("#"))
    .map((l) => { const i = l.indexOf("="); return [l.slice(0, i), l.slice(i + 1).replace(/^["']|["']$/g, "")]; }),
);

function token() {
  const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
  const now = Math.floor(Date.now() / 1000);
  const head = b64({ alg: "ES256", kid: env.ASC_KEY_ID, typ: "JWT" });
  const body = b64({ iss: env.ASC_ISSUER_ID, iat: now, exp: now + 600, aud: "appstoreconnect-v1" });
  const sig = createSign("SHA256").update(`${head}.${body}`).sign({ key: readFileSync(env.ASC_KEY_PATH), dsaEncoding: "ieee-p1363" });
  return `${head}.${body}.${sig.toString("base64url")}`;
}

async function get(path) {
  const res = await fetch(`https://api.appstoreconnect.apple.com${path}`, { headers: { Authorization: `Bearer ${token()}` } });
  if (!res.ok) throw new Error(`${res.status} ${path}: ${await res.text()}`);
  return res.json();
}

const [number, wait] = [process.argv[2] && !process.argv[2].startsWith("--") ? process.argv[2] : null, process.argv.includes("--wait")];
const apps = await get(`/v1/apps?filter[bundleId]=${BUNDLE_ID}`);
const app = apps.data[0];
if (!app) throw new Error(`No App Store Connect app for ${BUNDLE_ID}`);

for (let i = 0; ; i++) {
  const builds = await get(`/v1/builds?filter[app]=${app.id}&sort=-uploadedDate&limit=10&fields[builds]=version,processingState,uploadedDate`);
  for (const b of builds.data) console.log(`${b.attributes.version}\t${b.attributes.processingState}\t${b.attributes.uploadedDate}`);
  if (!wait || !number) break;
  const state = builds.data.find((b) => b.attributes.version === number)?.attributes.processingState;
  if (state === "VALID") process.exit(0);
  if (state === "INVALID" || state === "FAILED") process.exit(1);
  if (i >= 60) { console.log(`build ${number} not processed after 30 min`); process.exit(2); }
  console.log(`build ${number}: ${state ?? "not listed yet"}, checking again in 30 s`);
  await new Promise((r) => setTimeout(r, 30_000));
}
