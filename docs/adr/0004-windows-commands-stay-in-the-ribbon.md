# 4. Inkvolt PDF for Windows keeps its commands in the ribbon

Accepted, 2026-11-21.

## Context

The Mac builds its menus and command palette from one document command table (`DocumentCommands`, PdfCore) with what each
command needs. Windows has each command in the ribbon's XAML with its own CanExecute.

## Decision

Windows keeps the ribbon as it is. Its layout is hand-tuned, and the review found no bugs of the kind a table prevents.

## Consequences

Reopen it if commands start disagreeing about when they can run (a command enabled while busy or signing), or if the
palette and the ribbon drift apart.
