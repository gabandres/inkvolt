#!/bin/sh
# The Spanish interface's completeness check (roadmap 3.7): Xcode extracts every string the app's code shows (SwiftUI's
# literals, String(localized:)) and the catalogs' keys (`xcodebuild -exportLocalizations`, the same extraction Xcode's
# export uses), and this fails, naming each one, when any has no Spanish. PrintCore's and PrintMac's sentences
# (CoreStrings.xcstrings) are checked on the PC too, by CoreStringsTests. Run on the Mac:
#   sh mac/InkvoltPrint/check-strings.sh
set -eu
cd "$(dirname "$0")"
out="${TMPDIR:-/tmp}/inkvolt-print-strings"
rm -rf "$out"
xcodebuild -exportLocalizations -project InkvoltPrint.xcodeproj -localizationPath "$out" -exportLanguage es \
  CODE_SIGNING_ALLOWED=NO >"$out.log" 2>&1 || { tail -20 "$out.log"; echo "check-strings: the export failed" >&2; exit 2; }
xliff="$out/es.xcloc/Localized Contents/es.xliff"
/usr/bin/python3 - "$xliff" <<'PY'
import sys, xml.etree.ElementTree as ET
ns = {'x': 'urn:oasis:names:tc:xliff:document:1.2'}
left, total = [], 0
for f in ET.parse(sys.argv[1]).getroot().findall('x:file', ns):
    for u in f.findall('.//x:trans-unit', ns):
        total += 1
        target = u.find('x:target', ns)
        if target is None or not (target.text or '').strip():
            left.append(f"{f.get('original')}: {u.get('id')}")
for line in left:
    print('untranslated', line)
print(f'check-strings: {total - len(left)} of {total} strings in Spanish')
sys.exit(1 if left else 0)
PY
