#!/bin/sh
# Use Your Phone's page (roadmap 4.6) driven by curl on the Mac, as a phone's browser drives it, through the app's
# --phone-hold report (demo mode: 127.0.0.1 only, a certificate in a keychain file of the run's own). Run on the Mac from
# the repo after `sh mac/InkvoltPrint/build.sh`:  sh mac/tools/phone-client.sh full|slow|es
#   full: a wrong code, the page, pair, two photos, one not a photo, a chunked body, a second device, Done, a photo after
#   slow: a 2.5 MB photo at 20 KB/s while the Mac closes the window at 10 s;  es: the full pass with the app in Spanish
mode=${1:-full}
C="$HOME/Library/Containers/com.bermudezsystems.InkvoltPrint/Data/Library/Application Support/InkvoltPrint"
APP="/Applications/Inkvolt Print.app"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
sips -s format jpeg mac/InkvoltPrint/assets/store/06-scan.png --out "$T/a.jpg" >/dev/null 2>&1
sips -s format jpeg mac/InkvoltPrint/assets/store/07-photos.png --out "$T/b.jpg" >/dev/null 2>&1
sips -s format jpeg -s formatOptions 100 -z 4000 6000 mac/InkvoltPrint/assets/store/03-inkjet.png --out "$T/big.jpg" >/dev/null 2>&1
ls -l "$T" | awk 'NR>1 {print "  photo", $NF, $5, "bytes"}'
rm -f "$C/report-ph-$mode.txt" "$C/phone-hold-url.txt"
case $mode in
    slow) open -n "$APP" --args --report "ph-$mode" --wait 1 --demo --phone-hold 60 --close-after 10 ;;
    es) open -n "$APP" --args --report "ph-$mode" --wait 1 --demo --phone-hold 30 -AppleLanguages "(es)" ;;
    *) open -n "$APP" --args --report "ph-$mode" --wait 1 --demo --phone-hold 60 ;;
esac
i=0
while [ ! -s "$C/phone-hold-url.txt" ] && [ $i -lt 60 ]; do sleep 0.5; i=$((i + 1)); done
URL=$(cat "$C/phone-hold-url.txt" 2>/dev/null)
[ -n "$URL" ] || { echo "no address after 30 s"; exit 1; }
HOST=$(echo "$URL" | sed -E 's#https://([^/]+)/.*#\1#')
echo "address https://$HOST/p/<code>"
H="X-Inkvolt-Phone: 1"
J="$T/jar"
code() { curl -sk -o "$T/body" -w '%{http_code}' "$@"; }
echo "  wrong code GET: $(code "https://$HOST/p/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")"
echo "  wrong code pair: $(code -X POST -H "$H" "https://$HOST/p/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/pair")"
echo "  root GET: $(code "https://$HOST/")"
echo "  page GET: $(code -H 'Accept-Language: es-ES,es;q=0.9' "$URL") $(wc -c < "$T/body") bytes, $(grep -o '<html lang="[^"]*"' "$T/body"), h1: $(grep -o '<h1>[^<]*' "$T/body" | cut -c5-)"
grep -o '"sent":"[^"]*"' "$T/body" | sed 's/^/  /'
echo "  pair without page header: $(code -X POST "$URL/pair")"
echo "  pair: $(code -c "$J" -X POST -H "$H" "$URL/pair") $(cat "$T/body")"
if [ "$mode" = slow ]; then
    echo "  slow upload (20 KB/s) while the Mac closes at 10 s:"
    s=$(date +%s)
    r=$(curl -sk -o "$T/body" -w '%{http_code}' -b "$J" -X POST -H "$H" -H 'Content-Type: image/jpeg' --limit-rate 20k --data-binary @"$T/big.jpg" "$URL/photo"; echo " exit $?")
    echo "    answer $r after $(( $(date +%s) - s )) s: $(cat "$T/body" 2>/dev/null)"
    echo "    photo after close: $(code -b "$J" -X POST -H "$H" --data-binary @"$T/a.jpg" "$URL/photo") (exit $?)"
else
    echo "  photo 1: $(code -b "$J" -X POST -H "$H" -H 'Content-Type: image/jpeg' --data-binary @"$T/a.jpg" "$URL/photo") $(cat "$T/body")"
    echo "  photo 2: $(code -b "$J" -X POST -H "$H" -H 'Content-Type: image/jpeg' --data-binary @"$T/b.jpg" "$URL/photo") $(cat "$T/body")"
    echo "  not a photo: $(code -b "$J" -X POST -H "$H" --data-binary @mac/tools/phone-client.sh "$URL/photo") $(cat "$T/body")"
    echo "  chunked: $(code -b "$J" -X POST -H "$H" -H 'Transfer-Encoding: chunked' --data-binary @"$T/big.jpg" "$URL/photo")"
    echo "  second device pair: $(code -X POST -H "$H" "$URL/pair") $(cat "$T/body")"
    echo "  second device photo (2.5 MB): $(code -X POST -H "$H" --data-binary @"$T/big.jpg" "$URL/photo") $(cat "$T/body")"
    echo "  done: $(code -b "$J" -X POST -H "$H" "$URL/done") $(cat "$T/body")"
    echo "  photo after done: $(code -b "$J" -X POST -H "$H" --data-binary @"$T/a.jpg" "$URL/photo") (exit $?)"
fi
i=0
while [ ! -s "$C/report-ph-$mode.txt" ] && [ $i -lt 180 ]; do sleep 0.5; i=$((i + 1)); done
echo "--- report"
sed -n '/^phone hold:/,$p' "$C/report-ph-$mode.txt" 2>/dev/null || echo "no report"
pgrep -x "Inkvolt Print" >/dev/null && echo "app still running" || echo "app quit"
