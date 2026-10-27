import AppKit

// Inkvolt PDF: an AppKit document app (NSDocument per open PDF, windows as tabs), built without a storyboard.
let app = NSApplication.shared
let updates = Updates() // Sparkle's updater, started here, before the app finishes launching
let delegate = AppDelegate(updates: updates)
app.delegate = delegate
app.mainMenu = MainMenu.make(updates: updates)
app.setActivationPolicy(.regular)
app.run()
