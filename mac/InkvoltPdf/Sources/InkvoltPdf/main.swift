import AppKit
import PdfCore

// Inkvolt PDF: an AppKit document app (NSDocument per open PDF, windows as tabs), built without a storyboard.
// `InkvoltPdf --batch` and `--watch` run a saved Batch preset without a window (BatchCommandLine) and exit with its code.
let cliArguments = Array(CommandLine.arguments.dropFirst())
if BatchCommandLine.isCommand(cliArguments) {
    exit(Int32(CommandLineRun.run(cliArguments)))
}
// AppKit opens any argument that names something on disk as a document: the self-test's `--snapshots <folder>` would stop
// the run behind an error alert nobody can dismiss over SSH.
if cliArguments.contains("--self-test") { UserDefaults.standard.register(defaults: ["NSTreatUnknownArgumentsAsOpen": "NO"]) }
let app = NSApplication.shared
AppSettings.noteFirstRun() // before Sparkle writes its keys: a new install sees no What's New
let updates = Updates() // Sparkle's updater, started here, before the app finishes launching
let delegate = AppDelegate(updates: updates)
app.delegate = delegate
app.mainMenu = MainMenu.make(updates: updates)
app.setActivationPolicy(.regular)
app.run()
