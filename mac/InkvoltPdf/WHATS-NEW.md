# What's new in Inkvolt PDF for Mac

Shown in the app once after an update (Help › What's New any time) and used for the release notes of each download.
Each release gets a `## x.y.z` heading before it's made (`release.sh` warns when the version has none); `## Next`
collects what's done since the last release and is never shown. Short lines, in the user's words. `WHATS-NEW.es.md` is
their Spanish, line for line, shown when the app runs in Spanish: an English line needs its Spanish there (`PdfStringsTests`).

## Next
- Translate with AI keeps more of a paragraph's look: a regular word in a bold paragraph, a word in another color or another kind of font (a name in Times among Arial, code in a typewriter font), subscripts and superscripts at their own size and height, and a superscript longer than a footnote mark, however long (a list of references raised after a word stays whole). A long paragraph sent in parts keeps its look too, and so does text with a "<" or ">" of its own (p < 0.05). A line with a superscript or subscript gets the room it needs, so it doesn't run into the line above or below. Footnotes that each start with their own mark are translated apart, not run together.
- Translate with AI keeps underlined words underlined: the line drawn under them moves to the words that translate them, in its color and thickness.
- Translate with AI into Arabic or Hebrew keeps bold, italic, coloured and underlined words, subscripts and superscripts, each in its place in the right-to-left line.
- An Arabic or Hebrew translation opened in Firefox's PDF viewer (and the other viewers built on pdf.js) now keeps the spaces between its Arabic or Hebrew words when you copy or search it; they all used to run together.
- Translate with AI keeps up to three different colours or fonts in one paragraph (a red word and a name in Courier, say), each as it was; only the first was kept before.
- Translate with AI keeps more of what a small local model sends back: bold and italic it marks in its own way, and a label or name it puts in angle brackets, which used to be dropped.
- Titles in URW's bold Times (NimbusRomNo9L-Medi, as in many LaTeX papers) stay bold when translated or converted to Word, and LaTeX's math letters come out in italic.
- Redaction no longer lets the width of what you removed show. Text after a black box used to stay where it was, so the gap (and the box itself) could tell how long the hidden words were. Now each redacted line is laid out again: its words keep their order, spaces are even, and the box's width is rounded, so the line looks the same whatever was under it.
- Check Redaction also finds black boxes drawn into a page's picture (by tools that turn pages into images, or on a scan) with text beside them that may give the hidden width away.
- Make Accessible finds rows that share a label in tables drawn without lines (a region over its countries) and tags the label as spanning those rows, so a screen reader reads it with each of them.
- Accessibility Check compares the widths a PDF gives its characters with the font's own for every kind of embedded font, not just TrueType: CFF and Type 1 fonts too (most PDFs from InDesign, LaTeX and Acrobat).
- Batch runs a small file that unpacks to far more than its size (a 200 KB file holding 200 MB) on its own, so it no longer takes memory from the files beside it.
- Search Folders finds a phrase of common words with less reading: a file's pages are read together and shared among the Mac's processors, and a page of plain text is told quickly. A phrase that starts at the end of a run of letters and digits over 1,024 long (a long code or hash) is found too.
- Export to PowerPoint and HTML keeps the PDF's links: web and email links still open, and a link to another page goes to that slide or that part of the page. Only the words the link covers are linked. Reflow's column has the PDF's links too.
- Compare Files lines up a scanned page that was scanned at another size or a quarter turn off (sideways or upside down) with the other version before showing what looks different, so the same page no longer looks different all over.
- Compare Files straightens a scanned page and turns it the right way up before reading its words, as Recognize Text does. When it can't tell which way up a page goes, it reads the page both ways and keeps the reading with real words in your language, so a page scanned upside down is compared by its words.
- A page with a tiny picture built to unpack gigabytes (a damaged or malicious PDF) no longer takes seconds and then says "This page took too long to read": it shows at once.

## 1.13.0
- A PDF opened with its password showed blank white pages (its text could still be searched and copied). Its pages now show.
- Summary to Audio… (Tools › AI Assistant): your AI assistant's summary of the pages you choose, read aloud by Read Aloud's voice into an M4A (or WAV) file to listen to anywhere. Headings and bullets are read as sentences and page citations as "page 3", and it ends saying an AI model wrote it.
- Edit by Asking… (Tools › AI Assistant): say what to do in your own words, such as "rotate the last page and highlight every deadline", and your own AI assistant proposes the steps: go to a page, rotate or delete pages, add a bookmark, highlight a phrase, or find things to redact. You see every step and choose before anything runs, and Undo takes each edit back. Only your words, the page count and the page you're on are sent.
- Search by meaning (Inkvolt Pro): Search Folders' By meaning finds pages by what they mean, not only the words they use, and Ask Across Folders can bring them in too. Your own AI assistant's embedding model (such as nomic-embed-text) turns the pages into embeddings kept beside each folder's index; it's off until you turn it on (Meaning…), and the send window shows every page before it goes.
- Ask Across Folders… (Edit › Find, Inkvolt Pro): ask a question about the PDFs in your indexed folders, or PDFs you choose, and your own AI assistant answers from the pages most related to it. Each point cites its file and page, which open on a click, and the send window lists every page that goes, from which files.
- Save an AI answer: the Save button on an answer, or Tools › AI Assistant › Save AI Answer… and Save AI Conversation…, saves it as a Word document or a PDF, with what you asked, its page references and the model's name, or puts it into the document as a note on the page it cites. The conversation stays with the document while it's open.
- Suggest Redactions (Tools › Redact, Protect on the toolbar; Inkvolt Pro): your own AI assistant reads the pages and suggests names, companies, addresses and account numbers to redact, or whatever you describe, and you see exactly what is sent and where before it goes. Or keep your own list of names and terms, with no AI at all. Only words really on the page are kept; every place they appear goes into the same list as Redact by Pattern for you to accept or skip, and the result is read back and checked.
- Smaller black-and-white scans: Reduce File Size packs black-and-white pictures smaller (JBIG2 or CCITT G4, not a pixel lost), and can make scanned pages of text black and white if you ask. A black-and-white scan that Recognize Text cleans up stays black and white instead of turning grey and ten times larger.
- Turn a picture or a block of text to any angle (Edit Text & Images): drag a picture's round handle by its corner (hold Shift for 15° steps), type the angle in the paragraph editor's Angle box, or choose Edit › Turn to Angle…. Text stays text you can edit and search, and the rest of the page stays put.
- Rulers, guides and a grid (View menu, ⌥⇧⌘R and ⌥⌘'): drag a guide from a ruler, and form fields, shapes, stamps and measuring points snap to guides, the grid and the edges and middles of what's already on the page. The rulers count in the page's drawing scale when it has one. Hold ⌥ to place something without snapping.
- Calculated form fields (Prepare Form): a text field or dropdown can add up, multiply, average, or take the lowest or highest of the fields you tick, or work out a formula like Price * Quantity. They update as the form is filled, here and in Acrobat, which reads them back as its own. Tools › Forms › Calculation Order… sets which ones work out first. New number formats: negatives in brackets, 1.234,56 and euros.
- Several fields at once (Prepare Form): ⌘-click fields to select them together, then move them, delete them, line them up with the first one you picked, give them its width or height, or space them evenly across or down (the panel, or Tools › Forms › Arrange Fields).
- Proofreading marks (Tools › Annotate, Comment on the bar, and Control-click): Insert Text puts a blue caret where words should go in, with the words as its comment; Replace Text crosses out the selected words and puts a caret after them with what replaces them. They're the marks Acrobat makes, so Acrobat and other viewers show them the same way, and Replace Text is one comment in the Comments list, in Summarize Comments and in exported comments.
- Reflow (View menu, ⌘3): the document's text as one column that fits the window, for reading on a small screen or in large type. Zoom In makes the text bigger, Dark Pages makes it light on dark, and the page you were on is kept when you go back to the pages. Web and email links open in your browser or mail app.
- Two documents side by side: File › New Window (or the Dock icon's menu) opens the next document in a window of its own, or drag a tab out of the tab bar (Window › Move Tab to New Window does the same). A file that's open already comes forward in whichever window has it, and the documents you open join the window you used last.
- Replace Pages… (Pages menu): swap pages for pages of another PDF. Bookmarks and links that led to a replaced page now lead to the page that took its place.
- Resize Pages… (Pages menu): put pages on Letter, A4, Legal or a size you type, the content scaled to fit or kept at its size with margins added. Pages of mixed sizes become one size, and comments and form fields move with the content.
- Bookmarks from Headings… (Pages menu, and the Bookmarks list's menu): bookmarks made from the document's headings, nested by level and shown before they're made. They replace the bookmarks or go after them.
- Remove Blank Pages… (Pages menu) finds the pages that are almost all paper, shows them for you to untick any you want to keep, and deletes them in one step Undo puts back. Split at Blank Pages… saves the pages between blank separator sheets as separate PDFs. Both are Batch actions too.
- Interleave Pages… (Pages menu): two-sided sheets scanned one side at a time come back in order, front 1, back 1, front 2… The backs can be pages of the same file or another PDF, in reverse order (a stack turned over) or not. File › Scan the Backs… scans the backs straight into place.
- Page Labels… (Pages menu): number pages i, ii, iii or I, II, A, B, a, b, 1, 2, 3, with a prefix (A-1) and a first number, for any range: a preface in Roman numerals and the body from 1 in one step. Go to Page takes them.
- Find and Replace (Edit › Find): change a word or phrase across the document, one match at a time or all at once (one undo step), with Match case and Whole words only. Each match is listed with its page and the words around it. A replacement that can't be made as asked (a character no font has, a paragraph that would run into the text below) is listed afterwards.
- Spell check where you type: edited text, notes, text boxes, callouts, replies and form fields underline misspelled words in red, in the document's language. Control-click a word for suggestions, Ignore Spelling or Add to Dictionary. Turn it off in Settings.
- Copy Text from Area and Copy Area as Table (Edit menu): draw a box with Snapshot and copy the words in it, read from the picture when the page is a scan. As a table, it pastes into Numbers, Excel or Pages as cells. After a snapshot, Copy text on its message does the same.
- Links from Addresses (Tools › Annotate): every web and email address written in the document becomes a link you can click. You see the list first and can untick any; addresses that are links already are left alone. Undo removes them all in one step.
- Mark All Matches (Edit › Find): search for a word or phrase, then highlight, underline or strike out every match at once, each as a comment of its own. Matches marked already aren't marked twice, and Undo takes them all off in one step.

## 1.12.1
- A signed file's later changes can no longer hide behind the validation data it stores: a change to what a comment written into a page's list draws, to a page size or turn the pages inherit, or to the page order now shows as a change after signing.

## 1.12.0
- Redact by Pattern lists every match with its page and the words around it, beside the page itself: untick any you want to keep, then Redact. Scanned pages and pictures of text are searched through text recognition and flagged for you to look at, never called clean. Afterwards the result is read back, searched again and checked, and a report lists what was removed, masked.
- Inkvolt Pro: save sets of patterns and phrases, use your own pattern, run a set over a folder in Batch with a removal report (CSV) beside the results.
- Long-term validation (Inkvolt Pro): Sign Digitally can store the proof that your certificate was good when you signed, so the signature can still be checked after it expires (PAdES B-LT), and add a document timestamp over it (B-LTA). Fill & Sign › Add Verification Information… does the same for files signed earlier, and Batch for a folder of them.
- Before any of that goes online, a window lists every address that will be asked and what it gets. Addresses on this Mac or your network are never contacted, whatever a file's certificates name.
- Check Signatures Online… asks whether the certificates of a file's signatures were revoked, without changing the file. Opening or signing a file never goes online by itself, and each signature now says what the file holds for checking it later.
- Certifying a form can lock all its fields, the ones you choose, or all but those (Inkvolt Pro): a later change to a locked field shows as not allowed. Timestamps now go over https only; Sectigo's free server is suggested.

## 1.11.0
- Translate with AI (Tools › AI Assistant): a translated copy of the pages you choose opens beside the document and scrolls with it. Each paragraph stays in its box, tables cell by cell, with its bold, italic and small raised or lowered text; links move with the words they mark. It uses the AI endpoint you set up (on this Mac or yours), shows exactly what is sent before anything is, and can be stopped any time, keeping what's done. The document isn't changed.
- Edit Text & Images edits whole paragraphs: click a paragraph and type, and its text rewraps inside its box with its own font, alignment and line spacing. What follows stays put, and you're asked before longer text would run into it. The bar above the text gives a selection another font, size, color, bold or italic. A character the PDF's font lacks is drawn from the closest font on this Mac, and said.
- Fixed: in PDFs whose pages share their resources, a header, footer, watermark or flattening could leave other pages' text unreadable once saved. And PDFs made to freeze the app no longer stall paragraph editing or Translate.

## 1.10.0
- The toolbar is the command bar Windows has: Edit, Convert, Comment, Fill & Sign, Organize, Protect and Scan & OCR, each with its label. A click on a group does its main job; its arrow lists the rest, each with a line saying what it does. Convert › Word saves name.docx next to the PDF in one click (never over a file), opens it, and says "Saved name.docx · Show in Finder · Change options…"; Excel, PowerPoint, text and web page too. Option-click asks first. Sign, Highlight, Password and Recognize Text work in one click as well. Draw is in Comment, Redact in Protect.
- A one-click conversion never writes over a file another app saved under its name meanwhile, and a PDF whose name is cut to a name Windows can't use (such as CON) gets one it can, for Convert, Split and Extract alike.

## 1.9.0
- Search Folders (Edit › Find › Search Folders…, ⌥⇧⌘F): add a folder and Inkvolt PDF indexes every PDF in it and its subfolders on this Mac, then finds a word across all of them in a moment, with the text around each hit. A result opens at the hit. The index keeps up as files change, and says which files it couldn't read and why.
- Compare Files compares a Word, Excel or PowerPoint file (made into a PDF with LibreOffice) or a picture of a scanned page with a PDF. A scan's words are recognized on this Mac first; Compare Without Reading Them skips that.
- Compare Files lists font, size, bold, italic and color changes apart from changes to the words, and a paragraph that moved as one move, with any words edited inside it as their own changes. Running headers and page numbers are left out. A box for each kind hides it.
- Compare Files lines up two scans of a page that were fed a little crooked or shifted before overlaying them, and lists what looks different besides the words. Changes read from a scan that a recognizer often gets wrong (l and 1, O and 0) are marked as maybe misread. The annotated copy has all of it.
- Large drawings (plans and sheets with tens of thousands of lines) appear two to three times faster, drawn on all of the Mac's cores, and the next page is drawn ahead while you scroll.
- Protected forms that allow filling (many government forms, such as USCIS's) are filled and saved without asking for a password, and stay protected as they were.
- Social Security, phone and ZIP boxes with room for just the digits take them all; the dashes appear when you leave the field.
- More real forms work: radio buttons and fields their form lists oddly, check boxes that showed no tick, a list that kept showing its old choice, a field shown on several pages.
- Damaged PDFs keep what they hold when filled and saved: bookmarks and fields are no longer lost, and leftovers of an older copy no longer replace the form's values. A damaged file says so when it opens, and a signature made before the repair is never shown as valid.
- Forms made to freeze the app open and fill in moments: fields listed on thousands of pages, a check box picture that unpacks to gigabytes, a damaged file numbered in the millions. A field listed on more pages than are shown says so.

## 1.8.0
- Inkvolt PDF speaks Spanish: menus, windows, messages, reports and What's New follow the language you choose for it in macOS (System Settings › General › Language & Region › Applications) or in Settings › Language.
- Printing sends pages as they are, not as pictures: text and lines stay sharp at any size, and print jobs are many times smaller and faster to send. Comments, form fields, the layers shown and poster tiles print as before.
- Scan lists the scanners Inkvolt Print knows straight away, with their addresses, before the network search finds the rest; one that moved to a new address is found there.
- Scan presets: Save as Preset… keeps the source, color, resolution, page size, text recognition and blank page choices under a name. Choosing one sets them for whichever scanner is chosen, and says what that scanner can't do.
- Scan leaves out blank pages (on by default): the empty back of a one-sided sheet isn't added, and the message says how many were left out. A page with as little as a short word is kept.
- Snapshot (Tools › Snapshot, ⌥⌘C, or the camera in the markup toolbar): drag over part of a page to copy it as a picture, sharp enough to paste into a document or an email. Esc cancels.
- Printing to a printer Inkvolt Print knows shows its state and toner in the print panel (Inkvolt PDF's section), and warns in red when it's off or has a problem such as a paper jam, before you press Print.
- File › Printer Settings (Inkvolt Print), and a button in the print panel, open Inkvolt Print.
- Make Accessible gives text to the bitmap fonts of older TeX papers (Computer Modern drawn as pictures), so screen readers can read it.
- Make Accessible tags the text inside a drawing placed on the page (a whole page placed as one picture, a letterhead) piece by piece: each heading and paragraph in it gets its own tag.
- Make Accessible reads a ruled table's cell that spans rows as one cell, wherever its text sits in it, so a screen reader tells which rows a heading like "North" covers.
- The Reading Order pane can change what a piece is: choose its Kind (a heading and its level, paragraph, caption, footnote, formula or picture; a list can become a table of contents), then Apply Changes.
- Batch's Recognize Text (the Batch window, watched folders and `--batch`) reads scans as Tools › Recognize Text does, with its language and choices: the words it wasn't sure of are kept for review, the file's notes say how many, and opening the file lists them in the sidebar's Suspect Words.
- Exports to Word, Excel, PowerPoint, HTML and text that read scanned pages say how many suspect words there were, to check against the PDF.
- A page built to take minutes to read (a few kilobytes that unpack to gigabytes, a picture too large to decode, or a pattern of millions of tiles) no longer freezes the app: after a few seconds it says the page took too long to read, and the rest of the document can still be used. Find, Redact by Pattern, the redaction check, Prepare Form, Recognize Text and the AI assistant go on with the other pages and say which they skipped; Cancel and closing the document stop it at once. A page that's only slow to arrive (a network share, iCloud) or waiting while the Mac is busy isn't refused.
- Batch's Redact Patterns and Check Redaction fail a file with a page they couldn't read, and save nothing for it: what was looked for could still be on that page. Redact by Pattern and the check after Apply Redactions say which pages weren't looked at.
- A page that's too large or slow to read prints as a sentence saying so, never as an unbounded drawing that could freeze the app; the paper is always made from the same reading of the file as the screen. Pages already shown aren't checked again, and the others are checked without drawing them, so a long scan is ready to print in about a second.
- Check Redaction says when it couldn't look at everything (a page or a part of the file it couldn't read, more earlier versions than it checks), and which pages, instead of saying nothing was found.
- Batch presets, form data files and the AI assistant's answers can't hide deep nesting in JSON5 comments or strings to stop the app.

## 1.7.0
- Export and import comments (Tools › Annotate): XFDF for Acrobat and other PDF apps, FDF, or a CSV for spreadsheets. Replies, colors, authors and shapes come along; importing adds only what the document doesn't have yet, and one Undo takes it back.
- Form data as CSV and JSON too (File › Form Data): values are checked against their fields, and the ones the form doesn't take are listed.
- Fill Forms from CSV (File › Form Data): one filled copy of the form for each row of a spreadsheet, named as you like (any column can go in the name); rows the form refuses are listed in a report. Also from Terminal: `--fill`.
- Summarize Comments (Tools › Annotate): a PDF with each page beside its numbered list of comments and replies, ready to print or send.
- Batch can export comments (XFDF, FDF, CSV), form data (XFDF, FDF, CSV, JSON) and comment summaries for many files at once.
- Recognize Text turns a page over only when it reads clearly better that way, so a scanned page of numbers, which reads much the same either way up, stays as it is.
- One Inkvolt Pro key for both Mac apps: a key entered in Inkvolt PDF counts in Inkvolt Print, and the other way round (Help › Inkvolt Pro…). A key you entered before moves over by itself.

## 1.6.1
- Typing "inf" or a huge number as a watermark's picture width no longer makes Add Watermark quit the app the next time; Crop Pages refuses it too.
- Document Properties stays on screen for a PDF whose producer or creator text is very long: it's shortened on one line.
- Go to Page no longer hangs on a PDF with thousands of page-number styles or a very long page-label prefix.

## 1.6.0
- Simpler dialogs: the choices most people need are in sight, the rest under More Options (it remembers). Signing, headers and footers, watermarks, text recognition, Redact by Pattern, Reduce File Size and Batch got shorter, in plainer words.
- The markup tools sit right under the toolbar, in the same glass, as in Preview; the color is the Mac's own color picker.
- The window's subtitle shows the zoom next to the page number (Page 2 of 14 · 125%).
- Error messages say what happened in plain words, and Go to Page tells you which pages there are.
- Sanitize Document lists only what your document actually holds; Batch tells you what to add when its lists are empty.
- Every control in the dialogs has a name VoiceOver can read.
- The comment list in the sidebar follows the Mac's sidebar text size.
- A calmer window: a toolbar like Preview's (sidebar, zoom, Highlight, Markup, Fill & Sign, Share, Search), and the markup tools in a bar of their own that comes when you want it (the Markup button, View › Show Markup Toolbar ⇧⌘A, or any tool you pick). Add or remove buttons with View › Customize Toolbar….
- The Tools menu is grouped by what you're doing: Annotate, Fill & Sign, Redact, Forms, Measure, Accessibility, AI Assistant. Every tool keeps its key.
- The start page shows your recent files first and four tools; Show All Tools has the rest.
- The sidebar shows only the panes your document has (Signatures, Layers and Suspect Words appear when there is something in them).
- Settings apply as soon as you change them, as in other Mac apps.
- Document windows can be made much narrower, to sit beside another app.
- File › Share… sends the PDF by Mail, Messages or AirDrop.
- Compare Files: zoom in and out (⌘= and ⌘-, ⌘0 fits the window), and a Compare files card on the start page.
- Exports to Word, Excel, text, PowerPoint and HTML follow the layers you show or hide in the Layers pane, as printing does.
- Edit Text & Images: resize a picture by its handles (Shift keeps its proportions) and move it with the arrow keys (Shift: 10 points).
- An attached PDF that has a password of its own now opens: Inkvolt PDF asks for its password.
- Forms whose fields react when the pointer moves over them (a help text, a changed look) now do.
- Extract Pages… can make a new document, one file or a file per page, and delete the pages after. Split Document… (Pages menu) splits a PDF into files by a number of pages, by page ranges or at its bookmarks.
- Reverse Page Order (Pages menu): the last page first, in one step you can undo.
- Document Properties… (File menu, ⇧⌘I): the file's size, pages, page size, PDF version, protection and the app that made it; change its title, author, subject and keywords.
- Go to Page… (Go menu, ⌥⌘G): type a page number, or the page's label as the document numbers it (such as iv).
- Help › Report a Problem…: the details that help find a problem (version, macOS, a few settings; names and paths masked), to copy into a GitHub issue or an e-mail. Nothing is sent.
- Insert from Scanner (Pages menu): scan pages straight into the open document, after or before the current page or at either end, and make them searchable.
- Reading modes (View menu): Single Page (⌘4), Continuous (⌘5), Two Pages (⌘6) and Two Pages with Cover (⌘7), the cover alone on the right as in a printed book. New windows open in the mode you chose last.
- Drag thumbnails in the sidebar to move pages, or onto another window's thumbnails to copy them there. Drop PDFs or pictures from the Finder onto the thumbnails to insert them where you drop.
- Dark pages for night reading (View › Dark Pages, or Settings): white paper becomes dark grey and black text light grey, while colors keep their hue. Thumbnails follow; the file isn't changed.
- Rotate view (View › Rotate View Clockwise ⇧⌘R, Counterclockwise ⇧⌘L): turns the pages on screen only, without changing the file. Each window and split pane has its own; links, selection, fields and comments follow the turn, and a file reopens the way you left it.
- Fill & Sign keeps your signatures and initials between launches: up to three signatures and one set of initials, listed with their pictures in the Signature menu (and Tools › Place Saved Signature). Delete one from the same menu.
- Prepare Form: closing a document right after moving a field with the arrow keys keeps the move (it was lost).

## 1.5.0
- Find is several times faster on long documents (it reads pages on all but one of the Mac's cores, and remembers them for your next search), and a new search stops the one before it. Large files take about half the memory they did.
- Export to PowerPoint and HTML (File › Export To, and Batch): a slide per page with editable text boxes, headings as slide titles, tables, pictures and simple shapes; or one web page that reflows on any screen, with the alternate text the PDF's tags give, and no scripts or anything loaded from elsewhere.
- Recognize Text (OCR) cleans scanned pages first: it straightens them (up to 15°), turns sideways and upside-down pages upright, removes specks and evens out grey paper, and can replace the scans with the cleaned pages. Choose the language, or let it detect it. Words worth a second look (not in the dictionary, letters and digits mixed, odd characters) are listed in the sidebar's Suspect Words with their picture from the page: correct them or keep them as read (Tools › Review Suspect Words).
- Split view (View › Split View): the same document in two panes, top and bottom or side by side, each with its own page and zoom, to read two places at once. An edit in one shows in the other at once. Click a pane, or press ⌘', to switch; the × closes the second pane.
- Attachments and Layers in the sidebar (View › Show Attachments ⌥⌘5, Show Layers ⌥⌘6): see, save and remove the files attached to a PDF, attach your own, and open an attached PDF as its own document; show or hide a document's layers for viewing and printing without changing it, or save what you see as its default. The sidebar's buttons are now icons, with their names when you point at them.
- Read Aloud (View menu, ⇧⌘Y): reads from the top of the page in view, or just the selection, with a macOS voice; the sentence and word being read are highlighted and followed. A bar over the pages has pause, stop, previous and next paragraph, the voice and the speed (0.75×-2×).
- New PDF from Office File… and from Web Page… (File menu, and the start page's Create a PDF card): Word, Excel and PowerPoint files become PDFs through LibreOffice when it's installed (free, from libreoffice.org); a web address or a saved page is printed to a PDF with your paper, margins and backgrounds. Office files and saved pages also open straight from Finder or File › Open. The result opens as a new PDF; the original isn't changed.

## 1.4.1
- Fixed: a signature could still read as valid after a later change laid something over its page, through a field that only called itself a timestamp or a comment written straight into the page's list. Both now count as changes made after signing.
- Accessibility Check no longer calls a file a pass when part of it couldn't be checked (a very long page, forms nested too deep, a huge number of annotations or tags): it says "Not fully checked" and lists what wasn't, in the pane, the report and Batch, where such a file counts as failed.

## 1.4.0
- AI assistant (Tools › AI Assistant), off until you turn it on: connect an AI you choose, Ollama or LM Studio on this Mac or a service with your own key (kept in your keychain). Summarize pages, ask about the document in a pane at the right, or Control-click selected text › Explain with AI. Before anything is sent, a window shows where it goes and exactly what goes; answers are marked as AI-generated and link their page citations to the pages. Make Accessible's Reading Order pane can ask it to suggest a picture's alternate text. Inkvolt PDF has no AI of its own and Bermudez Systems receives nothing
- Make Accessible (Tools menu): tags a PDF for screen readers on this Mac, nothing sent anywhere: headings, paragraphs, lists, tables, contents, footnotes, formulas and pictures read from the pages, running headers and page numbers set aside, the title and language set. You can undo it until you save.
- Reading Order and Alt Text (Tools menu): the order a screen reader follows, as a list and as numbered boxes on the pages. Move a piece by drag, the buttons or ⌥↑ ⌥↓, even to the page before or after; type a picture's alternate text or mark it decorative; Apply Changes tags the document again.
- Save as PDF/A-2a (File menu): the archival copy that keeps the tags and says it is accessible. Batch has Make Accessible and Save as PDF/A-2a as actions.
- Fixed: Help › Inkvolt Pro… didn't open.
- Save as PDF/A now converts documents with Fill & Sign check marks and forms like the IRS's (their usage rights go, and the list of changes says so), and its copies drop pictures' and pages' own metadata, so they pass a formal check.
- Prepare Form (Tools menu, ⌥⌘F): make a PDF fillable. Drag text fields, check boxes, radio buttons, dropdowns, list boxes, signature fields and buttons onto the page, then set their names, defaults, formats and order in the panel on the right. Detect Form Fields finds the lines, boxes and underscores to fill in for you. The form fills in Acrobat, browsers and phones too.
- Measure (Tools menu): click to measure a distance, a perimeter or an area on drawings and plans, with the value shown by the pointer as you go. Set Measuring Scale… ("1 in = 10 ft", this page or all) or Calibrate from a length you know saves the scale in the PDF, and the scales a drawing already has are used where they apply. Each measurement is a comment labeled with its value, written the way Acrobat and Inkvolt PDF for Windows write them, so it reads the same there.
- Accessibility Check… (Tools menu): check a PDF against PDF/UA-1. Each problem says its Matterhorn number, where it is, what's wrong and what fixes it, and choosing it takes you there; a checklist covers what only a person can judge; Save Report… writes it all as one accessible web page. Batch has it as an action.
- Save as PDF/A-2b… (File menu): an archival copy of the document as it is now, for records that must open the same in years to come; the open document doesn't change. The copy gets a color profile and PDF/A metadata, loses what archives don't allow (scripts, attached files, password protection, hidden comments), and the standard fonts it uses get embedded. When something can't be kept without changing how the document looks (another font that isn't embedded, CMYK color, a digital signature), nothing is saved and each reason is listed. Batch has it too, as its last change.

## 1.3.0
- Compare Files… (File menu): pick the original and the changed version (an open document or any PDF) and see them side by side, page by page, with every inserted, removed and changed word marked on both sides and listed to step through. Text that only moved to the next page isn't a change; a removed or added page is one change. Visual overlays the pages (only in the original: red, only in the changed file: blue) for drawings and scans. Annotated Copy makes a copy of the changed file with every change as a comment, to save and share.
- Digital signatures: the Signatures pane in the sidebar (View › Show Signatures) checks every signature when you open a PDF and after each change: valid, changed after signing, changed in ways the signature doesn't allow, or invalid, with the signer, the time, the certificate and whether your Mac trusts it. Inkvolt PDF warns before an edit would invalidate a signature.
- Sign Digitally… (Tools menu, the Signature tool, or a click on an empty signature field): sign with a digital ID from your keychain (smart cards too), a .p12 file, or a personal ID made for you; drag where the signature goes, choose what it shows (your handwritten signature beside it, if you like), add a trusted timestamp or certify the document, then save the signed copy.
- Batch (File menu, and the start page): the same actions on many PDFs and pictures, saved to a folder with names from a template: reduce file size, protect or unprotect, sanitize, redact patterns, check redaction, report what's in each file, watermark, header and footer with Bates numbers, rotate, flatten, recognize text, export to Word, Excel, text, page images or form data. Save the list as a preset, export and import presets (the same files as on Windows), and watch folders: a file dropped in runs through a preset once it has finished copying.
- The command line: `InkvoltPdf --batch preset.json files…` and `--watch folder --preset preset.json` run a preset without a window, from a terminal or launchd (`--help` explains).
- Reduce File Size… (File menu): pictures downsampled to the chosen resolution, duplicates merged, streams compressed, unused objects dropped.
- Add Header & Footer… and Add Watermark… (Pages menu): page numbers, dates, Bates numbers, a text or a picture across the pages, written into them so they print everywhere; Remove takes them off again.
- Flatten… (Pages menu): comments and form fields become part of the pages.
- Help › Inkvolt Pro…: enter an Inkvolt Pro licence key, see whom it's licensed to, or remove it. Everything in Inkvolt PDF for Mac stays free while it launches, Pro features included; a licence ($19, one time, no account, checked on your Mac and never sent anywhere) supports the project and keeps those features for you when they start asking for a key. One key works on Windows and the Mac.

## 1.2.0
- What's in This PDF (Tools menu, and See What's in It… in Sanitize Document): one report of everything a PDF carries besides its pages: scripts and what they do, actions that run by themselves, every web address, file and program it can reach (marked when no click is needed), attachments, metadata and comment authors, signatures, earlier versions, hidden layers and text, form values and covers that hide nothing. It says what Sanitize removes, and saves as a web page or JSON. Nothing in the file is contacted.
- Edit Text & Images: clicking text on top of a picture edits the text.
- Redact by Pattern: a mistake in your own pattern is described in plain words.

## 1.1.0
- Redact: black out areas, selected text or every search match, or find Social Security, phone and card numbers, email addresses, dates, bank account numbers (IBAN), IP addresses, your own words or your own pattern, check the marks, then apply. What's under them is gone from the file, not just covered.
- Redaction check: after you apply redactions, Inkvolt PDF checks that nothing of what you redacted is left anywhere in the file and offers to fix what it finds. Tools › Check Redaction… checks any PDF for text still under black boxes or highlights, unapplied redaction marks and more.
- Sanitize Document (Tools menu): remove metadata, hidden layers, hidden comments and fields, scripts, links, attached files and earlier versions from a PDF before you share it.

## 1.0.0
- Read PDFs in tabs: smooth scrolling and zoom, thumbnails, the outline, find (match case, whole words), select and copy text, clickable links, full screen.
- Comments: highlight, underline, strike out, notes, text boxes, callouts, drawing (pen, highlighter, shapes, lines, arrows, polygons), stamps, pictures and links; replies, colors and a list of every comment.
- Forms: fill in text fields, check boxes, radio buttons and lists, with their calculations and formats; import and export form data.
- Fill & Sign: type anywhere, add check marks, dates and your signature or initials, drawn or typed.
- Edit Text & Images: change the words already on a page in their own font; move, replace or delete pictures.
- Recognize Text (OCR): make scanned pages searchable and their text copyable, with Apple's text recognition on your Mac.
- Export to Word, Excel or plain text.
- Organize pages: rotate, delete, duplicate, move, insert (from a PDF, pictures or blank pages), extract and crop; bookmarks.
- Combine files into one PDF, make a PDF from pictures or the clipboard, or scan pages straight into a new PDF (network scanners and USB scanners).
- Protect a PDF with a password, or remove its protection.
- Print with pages per sheet, booklets and posters.
- Undo and redo every change; saving keeps earlier signatures intact; recovery copies bring back unsaved work after a crash.
- A start page with the main tools, a command palette (⇧⌘K) that finds any command, and Settings (⌘,).
- Nothing you open leaves your Mac: no account, no tracking.
