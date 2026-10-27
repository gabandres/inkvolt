import AppKit

// Inkvolt PDF: an AppKit document app (NSDocument per open PDF, windows as tabs), built without a storyboard.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.mainMenu = MainMenu.make()
app.setActivationPolicy(.regular)
app.run()
