// Fills in Inkvolt Print's App Store listing for the version being prepared, from assets/store/listing.json and the
// screenshots beside it, through the App Store Connect API; and submits it for review.
//   node mac/InkvoltPrint/asc-listing.mjs apply <build number>   texts, categories, age rating, price (free), availability,
//                                                               content rights, review details, screenshots, the build
//   node mac/InkvoltPrint/asc-listing.mjs submit                  sends the version to App Review (Waiting for Review)
// The App Privacy answers ("Data Not Collected") can't be set through the API: publish them in App Store Connect first.
// The review contact is copied from another app of the team (listing.json's reviewContactFrom), so no phone number or
// address is kept in the repo.
import { createHash } from "node:crypto";
import { readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { HERE, all, api, app, get } from "./asc.mjs";

const L = JSON.parse(readFileSync(join(HERE, "assets", "store", "listing.json"), "utf8"));
const text = (v) => (Array.isArray(v) ? v.join("\n") : v);
const [command, buildNumber] = process.argv.slice(2);

const limits = { subtitle: 30, promotionalText: 170, keywords: 100, description: 4000 };
for (const [k, max] of Object.entries(limits)) {
  if (text(L[k]).length > max) throw new Error(`${k} is ${text(L[k]).length} characters (at most ${max})`);
}

const theApp = await app();
const version = (await get(`/v1/apps/${theApp.id}/appStoreVersions?filter[platform]=MAC_OS`)).data
  .find((v) => ["PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED"].includes(v.attributes.appStoreState));
if (!version) throw new Error("No macOS version in preparation");
const step = (what) => console.log(`- ${what}`);

if (command === "apply") await apply();
else if (command === "submit") await submit();
else throw new Error("usage: asc-listing.mjs apply <build> | submit");

async function apply() {
  if (!buildNumber) throw new Error("usage: asc-listing.mjs apply <build>");
  console.log(`${theApp.attributes.name} ${version.attributes.versionString} (${version.id})`);

  await api("PATCH", `/v1/apps/${theApp.id}`, {
    data: { type: "apps", id: theApp.id, attributes: { contentRightsDeclaration: "DOES_NOT_USE_THIRD_PARTY_CONTENT" } },
  });
  step("content rights: no third-party content");

  const info = (await get(`/v1/apps/${theApp.id}/appInfos`)).data.find((i) => i.attributes.state !== "READY_FOR_DISTRIBUTION");
  await api("PATCH", `/v1/appInfos/${info.id}`, {
    data: {
      type: "appInfos", id: info.id,
      relationships: {
        primaryCategory: { data: { type: "appCategories", id: L.primaryCategory } },
        secondaryCategory: { data: { type: "appCategories", id: L.secondaryCategory } },
      },
    },
  });
  step(`categories: ${L.primaryCategory}, ${L.secondaryCategory}`);

  const infoLoc = (await get(`/v1/appInfos/${info.id}/appInfoLocalizations`)).data.find((l) => l.attributes.locale === L.locale);
  await api("PATCH", `/v1/appInfoLocalizations/${infoLoc.id}`, {
    data: { type: "appInfoLocalizations", id: infoLoc.id, attributes: { name: L.name, subtitle: L.subtitle, privacyPolicyUrl: L.privacyPolicyUrl } },
  });
  step("name, subtitle, privacy policy URL");

  // Age rating: nothing of any kind (4+). Enumerations NONE, yes/no questions no.
  const age = (await get(`/v1/appInfos/${info.id}/ageRatingDeclaration`)).data;
  const booleans = ["advertising", "gambling", "healthOrWellnessTopics", "lootBox", "messagingAndChat", "parentalControls", "ageAssurance",
    "socialMedia", "unrestrictedWebAccess", "userGeneratedContent"];
  const enums = ["alcoholTobaccoOrDrugUseOrReferences", "contests", "gamblingSimulated", "gunsOrOtherWeapons", "medicalOrTreatmentInformation",
    "profanityOrCrudeHumor", "sexualContentGraphicAndNudity", "sexualContentOrNudity", "horrorOrFearThemes", "matureOrSuggestiveThemes",
    "violenceCartoonOrFantasy", "violenceRealisticProlongedGraphicOrSadistic", "violenceRealistic"];
  const answers = Object.fromEntries([...booleans.map((k) => [k, false]), ...enums.map((k) => [k, "NONE"])]
    .filter(([k]) => k in age.attributes));
  await api("PATCH", `/v1/ageRatingDeclarations/${age.id}`, { data: { type: "ageRatingDeclarations", id: age.id, attributes: answers } });
  step("age rating: none of the content questions");

  await api("PATCH", `/v1/appStoreVersions/${version.id}`, {
    data: { type: "appStoreVersions", id: version.id, attributes: { copyright: L.copyright, releaseType: "AFTER_APPROVAL" } },
  });
  step("copyright, release after approval");

  const loc = (await get(`/v1/appStoreVersions/${version.id}/appStoreVersionLocalizations`)).data.find((l) => l.attributes.locale === L.locale);
  await api("PATCH", `/v1/appStoreVersionLocalizations/${loc.id}`, {
    data: {
      type: "appStoreVersionLocalizations", id: loc.id,
      attributes: { description: text(L.description), keywords: L.keywords, promotionalText: L.promotionalText, supportUrl: L.supportUrl,
        marketingUrl: L.marketingUrl },
    },
  });
  step("description, keywords, promotional text, support and marketing URLs");

  await price();
  await availability();
  await reviewDetail();
  await screenshots(loc.id);

  const build = (await get(`/v1/builds?filter[app]=${theApp.id}&filter[version]=${buildNumber}&filter[preReleaseVersion.platform]=MAC_OS`)).data[0];
  if (!build || build.attributes.processingState !== "VALID") throw new Error(`Build ${buildNumber} isn't processed (VALID) yet`);
  await api("PATCH", `/v1/appStoreVersions/${version.id}/relationships/build`, { data: { type: "builds", id: build.id } });
  step(`build ${buildNumber}`);
  console.log("Applied. Next: App Privacy on the web (Data Not Collected), then `asc-listing.mjs submit`.");
}

/** Free, in every territory, from now on. */
async function price() {
  const points = await all(`/v1/apps/${theApp.id}/appPricePoints?filter[territory]=USA&limit=200`);
  const free = points.find((p) => Number(p.attributes.customerPrice) === 0);
  if (!free) throw new Error("No free price point for USA");
  await api("POST", "/v1/appPriceSchedules", {
    data: {
      type: "appPriceSchedules",
      relationships: {
        app: { data: { type: "apps", id: theApp.id } },
        baseTerritory: { data: { type: "territories", id: "USA" } },
        manualPrices: { data: [{ type: "appPrices", id: "${free}" }] },
      },
    },
    included: [{
      type: "appPrices", id: "${free}", attributes: { startDate: null },
      relationships: { appPricePoint: { data: { type: "appPricePoints", id: free.id } } },
    }],
  });
  step("price: free");
}

/** Every territory the App Store has, and new ones as they come. */
async function availability() {
  try {
    await get(`/v1/apps/${theApp.id}/appAvailabilityV2`);
    step("availability: already set");
    return;
  } catch (e) {
    if (!String(e.message).includes("404")) throw e;
  }
  const territories = await all("/v1/territories?limit=200");
  await api("POST", "/v2/appAvailabilities", {
    data: {
      type: "appAvailabilities",
      attributes: { availableInNewTerritories: true },
      relationships: {
        app: { data: { type: "apps", id: theApp.id } },
        territoryAvailabilities: { data: territories.map((t) => ({ type: "territoryAvailabilities", id: `\${${t.id}}` })) },
      },
    },
    included: territories.map((t) => ({
      type: "territoryAvailabilities", id: `\${${t.id}}`, attributes: { available: true },
      relationships: { territory: { data: { type: "territories", id: t.id } } },
    })),
  });
  step(`availability: ${territories.length} territories and new ones`);
}

/** The team's review contact (from another of its apps), no demo account, the notes. */
async function reviewDetail() {
  const other = await app(L.reviewContactFrom);
  const otherVersion = (await get(`/v1/apps/${other.id}/appStoreVersions?limit=1`)).data[0];
  const contact = (await get(`/v1/appStoreVersions/${otherVersion.id}/appStoreReviewDetail`)).data.attributes;
  const attributes = {
    contactFirstName: contact.contactFirstName, contactLastName: contact.contactLastName, contactPhone: contact.contactPhone,
    contactEmail: contact.contactEmail, demoAccountRequired: false, notes: text(L.reviewNotes),
  };
  const existing = await get(`/v1/appStoreVersions/${version.id}/appStoreReviewDetail`).catch(() => ({ data: null }));
  if (existing.data) {
    await api("PATCH", `/v1/appStoreReviewDetails/${existing.data.id}`, { data: { type: "appStoreReviewDetails", id: existing.data.id, attributes } });
  } else {
    await api("POST", "/v1/appStoreReviewDetails", {
      data: { type: "appStoreReviewDetails", attributes, relationships: { appStoreVersion: { data: { type: "appStoreVersions", id: version.id } } } },
    });
  }
  step("review contact and notes");
}

/** The desktop screenshots, replacing any there are, in listing order. */
async function screenshots(localizationId) {
  const sets = (await get(`/v1/appStoreVersionLocalizations/${localizationId}/appScreenshotSets`)).data;
  let set = sets.find((s) => s.attributes.screenshotDisplayType === "APP_DESKTOP");
  if (!set) {
    set = (await api("POST", "/v1/appScreenshotSets", {
      data: {
        type: "appScreenshotSets", attributes: { screenshotDisplayType: "APP_DESKTOP" },
        relationships: { appStoreVersionLocalization: { data: { type: "appStoreVersionLocalizations", id: localizationId } } },
      },
    })).data;
  }
  for (const old of (await get(`/v1/appScreenshotSets/${set.id}/appScreenshots`)).data) await api("DELETE", `/v1/appScreenshots/${old.id}`);
  for (const name of L.screenshots) {
    const path = join(HERE, "assets", "store", name);
    const bytes = readFileSync(path);
    const shot = (await api("POST", "/v1/appScreenshots", {
      data: {
        type: "appScreenshots", attributes: { fileName: name, fileSize: statSync(path).size },
        relationships: { appScreenshotSet: { data: { type: "appScreenshotSets", id: set.id } } },
      },
    })).data;
    for (const op of shot.attributes.uploadOperations) {
      const res = await fetch(op.url, {
        method: op.method, headers: Object.fromEntries(op.requestHeaders.map((h) => [h.name, h.value])),
        body: bytes.subarray(op.offset, op.offset + op.length),
      });
      if (!res.ok) throw new Error(`Uploading ${name}: ${res.status} ${await res.text()}`);
    }
    await api("PATCH", `/v1/appScreenshots/${shot.id}`, {
      data: { type: "appScreenshots", id: shot.id, attributes: { uploaded: true, sourceFileChecksum: createHash("md5").update(bytes).digest("hex") } },
    });
  }
  for (let i = 0; i < 40; i++) {
    const shots = (await get(`/v1/appScreenshotSets/${set.id}/appScreenshots`)).data;
    const states = shots.map((s) => s.attributes.assetDeliveryState?.state);
    if (states.every((s) => s === "COMPLETE")) break;
    if (states.includes("FAILED")) throw new Error(`A screenshot failed: ${JSON.stringify(shots.map((s) => s.attributes.assetDeliveryState))}`);
    await new Promise((r) => setTimeout(r, 3000));
  }
  step(`screenshots: ${L.screenshots.length}`);
}

/** A review submission with this version in it, sent: the version is then Waiting for Review. */
async function submit() {
  const open = (await get(`/v1/reviewSubmissions?filter[app]=${theApp.id}&filter[platform]=MAC_OS&filter[state]=READY_FOR_REVIEW`)).data[0];
  const submission = open ?? (await api("POST", "/v1/reviewSubmissions", {
    data: { type: "reviewSubmissions", attributes: { platform: "MAC_OS" }, relationships: { app: { data: { type: "apps", id: theApp.id } } } },
  })).data;
  const items = (await get(`/v1/reviewSubmissions/${submission.id}/items`)).data;
  if (items.length === 0) {
    await api("POST", "/v1/reviewSubmissionItems", {
      data: {
        type: "reviewSubmissionItems",
        relationships: {
          reviewSubmission: { data: { type: "reviewSubmissions", id: submission.id } },
          appStoreVersion: { data: { type: "appStoreVersions", id: version.id } },
        },
      },
    });
  }
  const sent = await api("PATCH", `/v1/reviewSubmissions/${submission.id}`, {
    data: { type: "reviewSubmissions", id: submission.id, attributes: { submitted: true } },
  });
  console.log(`Submitted: ${sent.data.attributes.state}`);
  const v = (await get(`/v1/appStoreVersions/${version.id}`)).data.attributes;
  console.log(`Version ${v.versionString}: ${v.appStoreState}`);
}
