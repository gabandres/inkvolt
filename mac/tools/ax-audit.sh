#!/bin/sh
# Both Mac apps' accessibility audit (PrintMac's AxWalk over PrintCore's AxAudit rules), on the build Mac, in English and
# Spanish, from the installed apps (build them first: mac/InkvoltPdf/build.sh, mac/InkvoltPrint/build.sh):
#   sh mac/tools/ax-audit.sh [pdf|print|both] [out-dir]     out-dir defaults to /tmp/inkvolt-ax
# Inkvolt PDF: --self-test <report> --lang <l> --ax-audit --synthetic --quit (Sparkle's automatic checks off for the run,
# as the release's self-test). Inkvolt Print: --report ax-<l> --demo --ax-audit --lang <l> (the report lands in its
# container). Prints each report's findings and its AX RESULT line; the full reports stay in out-dir.
set -eu
which=${1:-both}
out=${2:-/tmp/inkvolt-ax}
mkdir -p "$out"
pdf_domain=com.bermudezsystems.InkvoltPdf
print_report="$HOME/Library/Containers/com.bermudezsystems.InkvoltPrint/Data/Library/Application Support/InkvoltPrint"
if [ "$which" != print ]; then
    checks=$(defaults read "$pdf_domain" SUEnableAutomaticChecks 2>/dev/null || echo unset)
    update=$(defaults read "$pdf_domain" SUAutomaticallyUpdate 2>/dev/null || echo unset)
    # The automatic checks as they were (unset: Info.plist's default; `defaults read` says a bool as 0 or 1), also when
    # the run is interrupted or fails.
    restore() {
        case $2 in
            unset) defaults delete "$pdf_domain" "$1" 2>/dev/null || true ;;
            1) defaults write "$pdf_domain" "$1" -bool YES ;;
            *) defaults write "$pdf_domain" "$1" -bool NO ;;
        esac
    }
    restore_both() { restore SUEnableAutomaticChecks "$checks"; restore SUAutomaticallyUpdate "$update"; }
    trap restore_both EXIT
    trap 'exit 130' INT TERM
    defaults write "$pdf_domain" SUEnableAutomaticChecks -bool NO
    defaults write "$pdf_domain" SUAutomaticallyUpdate -bool NO
    for lang in en es; do
        rm -f "$out/pdf-$lang.txt"
        open -W -n -a "/Applications/Inkvolt PDF.app" --args --self-test "$out/pdf-$lang.txt" --lang "$lang" --ax-audit --synthetic --quit
        echo "== Inkvolt PDF ($lang)"
        grep -E "FINDING|^FAIL|AX RESULT" "$out/pdf-$lang.txt" || true
    done
    restore_both
    trap - EXIT
fi
if [ "$which" != pdf ]; then
    for lang in en es; do
        rm -f "$print_report/report-ax-$lang.txt"
        open -W -n -a "/Applications/Inkvolt Print.app" --args --report "ax-$lang" --wait 1 --lang "$lang" --demo --ax-audit
        echo "== Inkvolt Print ($lang)"
        cp "$print_report/report-ax-$lang.txt" "$out/print-$lang.txt" 2>/dev/null || { echo "no report (the run ended without one)"; continue; }
        grep -E "FINDING|AX RESULT|ax audit" "$out/print-$lang.txt" || true
    done
fi
