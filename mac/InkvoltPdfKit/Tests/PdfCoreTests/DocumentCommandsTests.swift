import Foundation
import Testing
@testable import PdfCore

/// The document command table (a Mac module, no Windows counterpart): the menu bar's commands once, and when each can
/// run over a document's state. The app's self-test (`MenuTest`) checks the menu bar AppKit builds from it.
struct DocumentCommandsTests {
    private func command(_ action: String) throws -> DocumentCommand {
        try #require(DocumentCommands.command(action: action), "no command sends \(action)")
    }

    /// A document as opened: three pages, from a file, nothing selected or running.
    private var opened: DocumentState {
        var s = DocumentState()
        s.hasDocument = true
        s.pageCount = 3
        s.hasSavedFile = true
        return s
    }

    @Test func The_menu_bar_has_its_menus_in_order() {
        #expect(DocumentCommands.menuBar.map(\.title) == ["Inkvolt PDF", "File", "Edit", "View", "Go", "Pages", "Tools", "Window", "Help"])
        #expect(DocumentCommands.all.count > 120)
    }

    @Test func Each_action_is_sent_by_one_command() {
        var seen: Set<String> = []
        for placed in DocumentCommands.all {
            let action = placed.command.action
            #expect(action.hasSuffix(":") && !action.dropLast().contains(":"), "\(action): one argument, the sender")
            #expect(seen.insert(action).inserted, "\(action) is sent by two commands")
        }
    }

    @Test func No_two_commands_share_a_key() {
        var seen: [String: String] = [:]
        for placed in DocumentCommands.all where !placed.command.key.isEmpty {
            let c = placed.command
            #expect(c.key == c.key.lowercased(), "\(c.title): a capital letter would add Shift")
            let id = "\(c.modifiers.rawValue)-\(c.key)"
            #expect(seen[id] == nil, "\(c.title) and \(seen[id] ?? "") share a key")
            seen[id] = c.title
        }
    }

    @Test func Titles_are_unique_in_each_menu() {
        var seen: Set<String> = []
        for placed in DocumentCommands.all {
            let id = (placed.path + [placed.command.title]).joined(separator: " › ")
            #expect(seen.insert(id).inserted, "\(id) twice")
        }
    }

    @Test func The_commands_named_in_jargon_carry_their_plain_note() throws {
        #expect(try command("flattenDocument:").note == PlainWords.note(for: "Flatten…"))
        #expect(try command("saveAsPdfA:").note != nil)
        #expect(try command("sanitizeDocument:").note != nil)
        #expect(try command("reviewSuspectWords:").note != nil)
        #expect(try command("openDocument:").note == nil)
        // Every note but the measuring tool's (a tool's title, not a command) names a command of the table.
        let titles = Set(DocumentCommands.all.map(\.command.title))
        for entry in PlainWords.entries where !entry.name.hasPrefix("Calibrate") {
            #expect(titles.contains(entry.name), "\(entry.name) is not a menu command")
        }
    }

    @Test func The_long_tasks_wait_while_the_document_is_busy() throws {
        let long = ["exportWord:", "recognizeText:", "reduceFileSize:", "flattenDocument:", "saveAsPdfA:", "makeAccessible:", "checkRedaction:"]
        var busy = opened
        busy.isBusy = true
        var redacting = opened
        redacting.redactionRunning = true
        for action in long {
            let c = try command(action)
            #expect(c.isEnabled(in: opened), "\(action) runs on an idle document")
            #expect(!c.isEnabled(in: busy), "\(action) waits for the long task")
            #expect(!c.isEnabled(in: redacting), "\(action) waits for the redaction")
        }
        // Only the long task rule: the others don't wait for a redaction being applied.
        #expect(try command("detectFormFields:").isEnabled(in: redacting))
        #expect(!(try command("detectFormFields:").isEnabled(in: busy)))
        #expect(!(try command("signDigitally:").isEnabled(in: busy)))
        #expect(!(try command("toggleReadingOrder:").isEnabled(in: busy)))
        // Commands that don't run long don't wait.
        #expect(try command("zoomIn:").isEnabled(in: busy))
        #expect(try command("showComments:").isEnabled(in: busy))
    }

    @Test func Deleting_or_reversing_pages_needs_two_pages() throws {
        var one = opened
        one.pageCount = 1
        for action in ["deletePages:", "reversePageOrder:"] {
            #expect(try command(action).isEnabled(in: opened))
            #expect(!(try command(action).isEnabled(in: one)), "\(action) would leave no page")
        }
        #expect(try command("rotatePagesLeft:").isEnabled(in: one))
    }

    @Test func Selection_commands_need_a_selection() throws {
        var selected = opened
        selected.hasSelectedText = true
        for action in ["linkSelectedText:", "redactSelectedText:", "aiExplain:"] {
            #expect(!(try command(action).isEnabled(in: opened)))
            #expect(try command(action).isEnabled(in: selected))
        }
        var answering = selected
        answering.aiBusy = true
        #expect(!(try command("aiExplain:").isEnabled(in: answering)))
        #expect(!(try command("aiSummarize:").isEnabled(in: answering)))
        #expect(try command("aiAsk:").isEnabled(in: answering))
        var comment = opened
        comment.hasSelectedComment = true
        #expect(!(try command("openInspector:").isEnabled(in: opened)))
        #expect(try command("openInspector:").isEnabled(in: comment) && command("replyToSelected:").isEnabled(in: comment))
    }

    @Test func What_a_document_holds_decides_its_commands() throws {
        #expect(!(try command("applyRedactions:").isEnabled(in: opened)))
        var marked = opened
        marked.hasRedactionMarks = true
        #expect(try command("applyRedactions:").isEnabled(in: marked) && command("clearRedactionMarks:").isEnabled(in: marked))
        marked.isBusy = true
        #expect(!(try command("applyRedactions:").isEnabled(in: marked)))

        var full = opened
        full.hasFormFields = true
        full.hasSignatures = true
        full.isProtected = true
        full.hasSearchMatches = true
        full.splitShown = true
        for action in ["resetForm:", "showSignatures:", "removeProtection:", "redactSearchMatches:", "removeSplit:", "switchPane:"] {
            #expect(!(try command(action).isEnabled(in: opened)), "\(action) off on a plain document")
            #expect(try command(action).isEnabled(in: full), "\(action) on when the document has it")
        }
        var unsaved = opened
        unsaved.hasSavedFile = false
        #expect(!(try command("reloadFromDisk:").isEnabled(in: unsaved)))
        var sheet = opened
        sheet.passwordSheetOpen = true
        #expect(!(try command("protectDocument:").isEnabled(in: sheet)))
        var organizing = opened
        organizing.organizerShown = true
        #expect(!(try command("toggleMarkup:").isEnabled(in: organizing)))
        #expect(try command("toggleOrganizer:").isEnabled(in: organizing))
    }

    @Test func Without_a_document_only_the_commands_that_need_nothing_run() throws {
        let none = DocumentState()
        #expect(!(try command("showDocumentProperties:").isEnabled(in: none)))
        #expect(!(try command("goToPage:").isEnabled(in: none)))
        #expect(!(try command("setMeasuringScale:").isEnabled(in: none)))
        #expect(try command("newWindow:").isEnabled(in: none))
        // An action no command sends (a tool's chooseTool:) is the window's own to check.
        #expect(DocumentCommands.isEnabled(action: "chooseTool:", in: none))
    }

    @Test func The_tools_submenus_are_tools_menus() throws {
        let tools = try #require(DocumentCommands.menuBar.first { $0.title == "Tools" })
        var roles: [String: MenuRole] = [:]
        func walk(_ menu: CommandMenu) {
            for case .submenu(let sub) in menu.resolvedEntries {
                roles[sub.title] = sub.role
                walk(sub)
            }
        }
        walk(tools)
        for title in ["Annotate", "Fill & Sign", "Redact", "Forms", "Measure", "Accessibility", "AI Assistant"] {
            #expect(roles[title] == .tools, "\(title)")
        }
        #expect(roles["Place Saved Signature"] == .savedSignatures)
    }
}
