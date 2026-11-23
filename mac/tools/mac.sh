#!/usr/bin/env bash
# Work on the Mac from the Windows PC in one call per step (Git Bash). The PC's working tree, uncommitted changes and new
# files included, goes to the Mac as a git commit object pushed straight over SSH (no GitHub, no file copying, LF endings
# and binaries as git stores them); the PC's branch, index and stash are left alone. The Mac checks it out in its own
# worktree, ~/Repos/inkvolt-pc, so the release clone ~/Repos/inkvolt and the agents' worktrees aren't touched, and its
# .build caches stay warm between runs.
#
#   mac/tools/mac.sh sync                       the working tree to the Mac
#   mac/tools/mac.sh run '<command>'            sync, then run a command in the Mac worktree (-n: without syncing)
#   mac/tools/mac.sh pdf-test [filter]          sync, swift test InkvoltPdfKit (only `filter` if given), summary only
#   mac/tools/mac.sh print-test [filter]        the same for InkvoltPrintKit
#   mac/tools/mac.sh pdf-app [args…]            sync, build and install Inkvolt PDF.app (mac/InkvoltPdf/build.sh)
#   mac/tools/mac.sh bg <name> '<command>'      sync, run detached; log in ~/build-logs/<name>.log, exit code in <name>.status
#   mac/tools/mac.sh log <name> [lines]         the end of a detached run's log and its status
#   mac/tools/mac.sh wait <name> [lines] [s]    waits (at most s seconds, default 1800) for a detached run, then `log`
#
# Long runs (a full test pass, the app's --self-test) go through `bg`, then `wait` (as a background command) or `log`, so no
# SSH session waits on them and nobody polls with sleep.
#
# Agents working at once each set INKVOLT_MAC_SLOT=<short name>: their own Mac worktree (~/Repos/inkvolt-<slot>), sync ref
# and log names, so their trees and .build caches don't collide. Unset, the slot is `pc` (~/Repos/inkvolt-pc).
# /Applications' installed apps stay shared: one slot at a time builds and drives an app.
set -euo pipefail

HOST=${INKVOLT_MAC_HOST:-buildmac}
MAIN='~/Repos/inkvolt'
SLOT=${INKVOLT_MAC_SLOT:-pc}
case $SLOT in *[!a-z0-9-]*|'') echo "INKVOLT_MAC_SLOT: lowercase letters, digits and dashes only"; exit 2 ;; esac
WT="~/Repos/inkvolt-$SLOT"
if [ "$SLOT" = pc ]; then REF=refs/pc/sync; LOGP=; else REF=refs/pc/$SLOT; LOGP=$SLOT-; fi
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=8 "$HOST")
ROOT=$(git rev-parse --show-toplevel)
SLOW='-Xswiftc -Xfrontend -Xswiftc -warn-long-expression-type-checking=150'

remote() { "${SSH[@]}" "$@"; }

sync() {
    cd "$ROOT"
    local index tree commit
    index=$(mktemp)
    cp "$(git rev-parse --git-dir)/index" "$index"
    GIT_INDEX_FILE=$index git -c core.safecrlf=false add -A 2>/dev/null
    tree=$(GIT_INDEX_FILE=$index git write-tree)
    rm -f "$index"
    commit=$(git commit-tree "$tree" -p HEAD -m "PC working tree $(date +%FT%T)")
    # The Mac's main clone receives the objects; its checked-out branch isn't touched.
    git push -q "$HOST:Repos/inkvolt" "$commit:$REF" -f
    remote "set -e
        cd $MAIN
        if [ ! -d $WT ]; then git worktree add -q --detach $WT $REF; fi
        cd $WT
        git checkout -q -f --detach $REF
        git clean -q -fd -e .build -e Frameworks
        # MuPDF's XCFramework isn't in git: the release clone's build is shared.
        [ -e mac/InkvoltPdfKit/Frameworks ] || ln -s $MAIN/mac/InkvoltPdfKit/Frameworks mac/InkvoltPdfKit/Frameworks
        echo \"synced \$(git rev-parse --short HEAD) (on $(git -C "$ROOT" rev-parse --short HEAD))\""
}

# swift test's output cut to what matters: failures, warnings in our code, the summary.
summarize() {
    grep -E "error:|warning:|✘|failed|Test run with|Executed|passed after|issue" | grep -v "/.build/checkouts/" | tail -n 60
}

test_pkg() {
    local pkg=$1 filter=${2:-}
    sync
    remote "cd $WT && swift test --package-path mac/$pkg $SLOW ${filter:+--filter '$filter'} 2>&1" | summarize
}

case ${1:-} in
    sync) sync ;;
    run)
        shift
        if [ "${1:-}" = -n ]; then shift; else sync; fi
        # The command goes on stdin, so its quotes and pipes reach the Mac's shell as written.
        printf '%s
' "$*" | remote "cd $WT && zsh -l -s"
        ;;
    pdf-test) test_pkg InkvoltPdfKit "${2:-}" ;;
    print-test) test_pkg InkvoltPrintKit "${2:-}" ;;
    pdf-app)
        shift
        sync
        remote "cd $WT && sh mac/InkvoltPdf/build.sh $* 2>&1 | tail -n 30"
        ;;
    bg)
        name=$LOGP$2
        shift 2
        sync
        printf 'cd %s
%s
' "$WT" "$*" | remote "mkdir -p ~/build-logs && cat > ~/build-logs/$name.sh"
        remote "rm -f ~/build-logs/$name.status; nohup zsh -l -c 'zsh ~/build-logs/$name.sh > ~/build-logs/$name.log 2>&1; echo \$? > ~/build-logs/$name.status' >/dev/null 2>&1 & echo started $name"
        ;;
    log)
        set -- "$1" "$LOGP$2" "${@:3}"
        remote "tail -n ${3:-40} ~/build-logs/$2.log; echo; if [ -f ~/build-logs/$2.status ]; then echo \"exit \$(cat ~/build-logs/$2.status)\"; else echo running; fi"
        ;;
    wait)
        set -- "$1" "$LOGP$2" "${@:3}"
        # Short SSH calls every 10 s (a dropped connection costs one try, not the run); exits with the run's own code.
        deadline=$((SECONDS + ${4:-1800}))
        until remote "test -f ~/build-logs/$2.status" 2>/dev/null; do
            if [ $SECONDS -ge $deadline ]; then echo "still running after ${4:-1800} s"; exit 124; fi
            sleep 10
        done
        remote "tail -n ${3:-40} ~/build-logs/$2.log; echo; echo \"exit \$(cat ~/build-logs/$2.status)\""
        exit "$(remote "cat ~/build-logs/$2.status" | tr -dc 0-9)"
        ;;
    *) sed -n '2,24p' "$0"; exit 2 ;;
esac
