// A small App Store Connect API client for Inkvolt Print's scripts (asc-builds.mjs, asc-listing.mjs). It signs a
// short-lived ES256 token with the API key named in .env.local beside this file (ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH;
// not in git), with Node's own crypto: no packages.
import { createSign } from "node:crypto";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export const HERE = dirname(fileURLToPath(import.meta.url));
export const BUNDLE_ID = "com.bermudezsystems.InkvoltPrint";

const env = Object.fromEntries(
  readFileSync(join(HERE, ".env.local"), "utf8")
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

/** One API call; JSON in and out. Throws with Apple's error text on a failure status. */
export async function api(method, path, body) {
  const res = await fetch(`https://api.appstoreconnect.apple.com${path}`, {
    method,
    headers: { Authorization: `Bearer ${token()}`, ...(body ? { "Content-Type": "application/json" } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`${method} ${path} -> ${res.status}: ${text}`);
  return text ? JSON.parse(text) : null;
}

export const get = (path) => api("GET", path);

/** Every page of a list. */
export async function all(path) {
  const out = [];
  let next = path;
  while (next) {
    const page = await get(next);
    out.push(...page.data);
    next = page.links?.next ? page.links.next.replace("https://api.appstoreconnect.apple.com", "") : null;
  }
  return out;
}

export async function app(bundleId = BUNDLE_ID) {
  const found = (await get(`/v1/apps?filter[bundleId]=${bundleId}`)).data.find((a) => a.attributes.bundleId === bundleId);
  if (!found) throw new Error(`No App Store Connect app for ${bundleId}`);
  return found;
}
