"""The build's "Catalog keys" phase: every key of the app's String Catalogs (Resources/Localizable.xcstrings and
CoreStrings.xcstrings), written into the bundle as CatalogKeys.json ({"Localizable": [...], "CoreStrings": [...]}) for
`--report … --strings` (ReportStrings). The compiled English tables can't stand for the catalogs: Xcode writes only the
keys whose English differs from the key into them (34 of Localizable's 600). Stale keys and those marked not to
translate are left out, as Xcode leaves them out of a translation.
    /usr/bin/python3 catalog-keys.py <Resources folder> <CatalogKeys.json> [<catalog.xcstrings>…]
Inkvolt PDF's assemble.sh names its catalogs (Localizable, PdfStrings and this app's CoreStrings), each table named after
its file."""
import json, os, sys

resources, out = sys.argv[1], sys.argv[2]
catalogs = sys.argv[3:] or [os.path.join(resources, t + ".xcstrings") for t in ("Localizable", "CoreStrings")]
keys = {}
for path in catalogs:
    table = os.path.splitext(os.path.basename(path))[0]
    with open(path, encoding="utf-8") as f:
        strings = json.load(f)["strings"]
    keys[table] = sorted(k for k, e in strings.items()
                         if e.get("extractionState") != "stale" and e.get("shouldTranslate", True))
os.makedirs(os.path.dirname(out), exist_ok=True)
with open(out, "w", encoding="utf-8") as f:
    json.dump(keys, f, ensure_ascii=False)
