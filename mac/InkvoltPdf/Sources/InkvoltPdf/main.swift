import AppKit
import PdfCore

// Inkvolt PDF: an AppKit document app (NSDocument per open PDF, windows as tabs), built without a storyboard.
// `InkvoltPdf --batch` and `--watch` run a saved Batch preset without a window (BatchCommandLine) and exit with its code.
let cliArguments = Array(CommandLine.arguments.dropFirst())
// The Inkvolt Pro check (the key in the file both Inkvolt apps share): the command line asks it too, so it is set up before
// it runs (AppDelegate sets it again once the self-test may have moved the settings to its own suite).
ProSetup.configure(selfTest: cliArguments.contains("--self-test"))
if BatchCommandLine.isCommand(cliArguments) {
    exit(Int32(CommandLineRun.run(cliArguments)))
}
// AppKit opens any argument that names something on disk as a document: the self-test's `--snapshots <folder>` would stop
// the run behind an error alert nobody can dismiss over SSH.
if cliArguments.contains("--self-test") || cliArguments.contains("--lang") {
    UserDefaults.standard.register(defaults: ["NSTreatUnknownArgumentsAsOpen": "NO"])
}
// The interface's language, before the menu bar and the first window (the command line above stays English).
AppLanguage.apply(cliArguments)
// The first document controller made is the one AppKit keeps: ours converts Office files and saved web pages on Open.
_ = DocumentController()
let app = NSApplication.shared
AppSettings.noteFirstRun() // before Sparkle writes its keys: a new install sees no What's New
let updates = Updates() // Sparkle's updater, started here, before the app finishes launching
let delegate = AppDelegate(updates: updates)
app.delegate = delegate
app.mainMenu = MainMenu.make(updates: updates)
app.setActivationPolicy(.regular)
app.run()
