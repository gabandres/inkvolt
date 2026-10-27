// Creates an Apple Development certificate for the team from a certificate signing request, with the App Store Connect
// API key in .env.local, and writes it (DER) where dev-cert.sh imports it.
//   node mac/InkvoltPrint/asc-dev-cert.mjs <request.csr> <out.cer>
import { readFileSync, writeFileSync } from "node:fs";
import { api } from "./asc.mjs";

const [csrPath, outPath] = process.argv.slice(2);
if (!csrPath || !outPath) {
  console.error("usage: node asc-dev-cert.mjs <request.csr> <out.cer>");
  process.exit(2);
}
const csr = readFileSync(csrPath, "utf8").replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
const res = await api("POST", "/v1/certificates", {
  data: { type: "certificates", attributes: { certificateType: "DEVELOPMENT", csrContent: csr } },
});
const a = res.data.attributes;
writeFileSync(outPath, Buffer.from(a.certificateContent, "base64"));
console.log(`${a.name} (${a.displayName ?? ""}), serial ${a.serialNumber}, expires ${a.expirationDate}`);
