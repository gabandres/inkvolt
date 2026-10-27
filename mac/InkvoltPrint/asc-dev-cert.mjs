// Creates a certificate for the team from a certificate signing request, with the App Store Connect API key in
// .env.local, and writes it (DER) where dev-cert.sh or devid-cert.sh imports it. The type: DEVELOPMENT (the default, an
// Apple Development certificate) or DEVELOPER_ID_APPLICATION_G2 (Developer ID Application, for apps outside the store).
//   node mac/InkvoltPrint/asc-dev-cert.mjs <request.csr> <out.cer> [type]
import { readFileSync, writeFileSync } from "node:fs";
import { api } from "./asc.mjs";

const [csrPath, outPath, type = "DEVELOPMENT"] = process.argv.slice(2);
if (!csrPath || !outPath) {
  console.error("usage: node asc-dev-cert.mjs <request.csr> <out.cer> [type]");
  process.exit(2);
}
const csr = readFileSync(csrPath, "utf8").replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
const res = await api("POST", "/v1/certificates", {
  data: { type: "certificates", attributes: { certificateType: type, csrContent: csr } },
});
const a = res.data.attributes;
writeFileSync(outPath, Buffer.from(a.certificateContent, "base64"));
console.log(`${a.name} (${a.displayName ?? ""}), serial ${a.serialNumber}, expires ${a.expirationDate}`);
