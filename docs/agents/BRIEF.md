# Standing brief for an agent on Inkvolt

Your task's own prompt says what to build; this says how every Inkvolt agent works. Read the root `CLAUDE.md` too (and
`mac/CLAUDE.md` for anything under `mac/`).

## Where the work goes

- Work in your worktree and commit on its branch: one commit per item, the message in the style of `git log --oneline -6`,
  ending with the `Co-Authored-By:` line your task gives. The orchestrator reviews, merges and pushes; you don't push or
  merge.
- Delete a merged branch with `git branch -d`; the hook refuses the capital form.

## Waiting

- A long command runs in the background (`run_in_background`, or the Monitor tool for a condition); you are told when it
  ends. On the Mac: `mac.sh bg <name> '<cmd>'`, then `mac.sh wait <name>` as a background command.

## Checks

- Windows: `pwsh -NoProfile -File tools/test.ps1` (all green, 0 warnings; a test it names as flaky is fine, say which).
  Mac: `mac/CLAUDE.md`'s Done. Run the tools the root `CLAUDE.md` names for what you changed (export-corpus, pdfjs-check,
  bench).
- Check a change in the real app where it can be driven (Inkvolt PDF's `--script`, Inkvolt Print's `--demo --snapshot`,
  the Mac apps' `--report` and `--self-test`), and say what only a person can check on screen.
- `CODING_STANDARDS.md` is what review looks for: hostile input, one behaviour in one module, Spanish strings.

## Secrets and data

- `.env.local` and App Store Connect keys: the repo's scripts use them; you never print, copy or paste a value.
- The Inkvolt Pro signing key (`C:\Users\gabri\.inkvolt-pro\`): never read or used.
- No new package without the owner; no telemetry; no real printer's serial, IP, hostname or UUID in the repo.
- No release, upload, submission or notarization unless the task says the owner asked for it.

## Your final reply

Under 250 words, in this order: branch and commit SHAs; what changed (module names, files); tests added and totals; the
checks run and their results; what only a person can check; what was skipped and why.
