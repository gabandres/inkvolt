// Lists Inkvolt Print's macOS builds in App Store Connect and their processing state, so an upload is checked where it
// lands (altool has reported success for builds that never arrived).
//   node mac/InkvoltPrint/asc-builds.mjs [build number] [--wait]
// --wait polls every 30 s (up to 30 min) until that build is VALID (exit 0), or INVALID/FAILED (exit 1).
import { app, get } from "./asc.mjs";

const [number, wait] = [process.argv[2] && !process.argv[2].startsWith("--") ? process.argv[2] : null, process.argv.includes("--wait")];
const { id } = await app();

for (let i = 0; ; i++) {
  const builds = await get(`/v1/builds?filter[app]=${id}&sort=-uploadedDate&limit=10&fields[builds]=version,processingState,uploadedDate`);
  for (const b of builds.data) console.log(`${b.attributes.version}\t${b.attributes.processingState}\t${b.attributes.uploadedDate}`);
  if (!wait || !number) break;
  const state = builds.data.find((b) => b.attributes.version === number)?.attributes.processingState;
  if (state === "VALID") process.exit(0);
  if (state === "INVALID" || state === "FAILED") process.exit(1);
  if (i >= 60) { console.log(`build ${number} not processed after 30 min`); process.exit(2); }
  console.log(`build ${number}: ${state ?? "not listed yet"}, checking again in 30 s`);
  await new Promise((r) => setTimeout(r, 30_000));
}
