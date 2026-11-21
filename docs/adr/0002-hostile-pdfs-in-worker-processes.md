# 2. Hostile PDF work runs in worker processes

Accepted (recorded 2026-11-21; built from 2026-10).

## Context

A PDF can hang MuPDF, exhaust its memory or crash it. In process, that takes the user's open documents with it.

## Decision

Work over many pages or files that the user didn't open runs in the app started again as a worker over a private pipe: the
find worker (one long search), the index worker (the only thing that parses a PDF for the folder index) and the page check
(a page drawn small, with a time and memory limit, before the app first runs its content). A worker that fails costs that
worker; the page is refused or the file skipped, and the app goes on (`pdf/GLOSSARY.md`).

## Consequences

- Don't move this work back in process for speed; make the worker faster or start it sooner.
- The Mac has no workers (sandboxing); it uses reading threads, a watchdog and a crash journal instead. That difference is
  deliberate, not a gap to close.
