#!/usr/bin/env bash
# Inkvolt PDF/Print's Mac commands, on top of `mac` (Z:\machines\bin\mac, on Git Bash's PATH; Z:\machines\README.md), the
# one way every repo reaches the build Mac. `mac` sends the PC's working tree, uncommitted and new files included, to the
# worktree ~/Repos/inkvolt-pc as a git commit object (no GitHub, no file copying; the PC's branch, index and stash are
# left alone), so the release clone ~/Repos/inkvolt isn't touched and the worktree's .build caches stay warm.
#
#   mac/tools/mac.sh pdf-test [filter]          sync, swift test InkvoltPdfKit (only `filter` if given), summary only
#   mac/tools/mac.sh print-test [filter]        the same for InkvoltPrintKit
#   mac/tools/mac.sh pdf-app [args…]            sync, build and install Inkvolt PDF.app (mac/InkvoltPdf/build.sh)
#   mac/tools/mac.sh <anything else>            `mac` itself: sync, run '<cmd>', bg <name> '<cmd>', wait <name>, log <name>,
#                                               jobs, get <path>, status (bare `mac` prints its help)
#
# Long runs (a full test pass, the app's --self-test) go through `bg`, then `wait` (as a background command), so no SSH
# session waits on them and nobody polls with sleep. `run` and `bg` refuse while someone is using the Mac (exit 75).
#
# Agents working at once each set INKVOLT_MAC_SLOT=<short name> (or MAC_SLOT): their own Mac worktree
# (~/Repos/inkvolt-<slot>), sync ref and job names, so their trees and .build caches don't collide. Unset, the slot is
# `pc`. /Applications' installed apps stay shared: one slot at a time builds and drives an app.
set -euo pipefail

[ -n "${INKVOLT_MAC_HOST:-}" ] && export MAC_HOST=${MAC_HOST:-$INKVOLT_MAC_HOST}
MAC=$(command -v mac || echo /z/machines/bin/mac)
SLOW='-Xswiftc -Xfrontend -Xswiftc -warn-long-expression-type-checking=150'
# swift test's output cut, on the Mac, to what matters: failures, warnings in our code, the summary.
SUMMARY='grep -E "error:|warning:|✘|failed|Test run with|Executed|passed after|issue" | grep -v "/.build/checkouts/" | tail -n 60'

case ${1:-} in
    pdf-test|print-test)
        [ "$1" = pdf-test ] && pkg=InkvoltPdfKit || pkg=InkvoltPrintKit
        filter=${2:-}
        exec "$MAC" run "swift test --package-path mac/$pkg $SLOW ${filter:+--filter '$filter'} 2>&1 | $SUMMARY"
        ;;
    pdf-app)
        shift
        exec "$MAC" run "sh mac/InkvoltPdf/build.sh $* 2>&1 | tail -n 30"
        ;;
    wait)
        # The old form was `wait <name> [lines] [seconds]`; `mac wait` takes `<name> [seconds]`.
        if [ $# -ge 4 ]; then exec "$MAC" wait "$2" "$4"; else exec "$MAC" wait "$2"; fi
        ;;
    '') sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
    *) exec "$MAC" "$@" ;;
esac
