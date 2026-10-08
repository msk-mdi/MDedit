import AppKit

/// The menu bar, built in code — no nib, no storyboard.
@MainActor
enum MainMenu {
    static func install(into app: NSApplication) {
        let main = NSMenu()
        main.addItem(appMenu())
        main.addItem(fileMenu())
        main.addItem(editMenu())
        main.addItem(formatMenu())
        main.addItem(viewMenu())
        main.addItem(windowMenu(app: app))
        main.addItem(helpMenu())
        app.mainMenu = main
    }

    private static func submenu(_ title: String, _ build: (NSMenu) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        build(menu)
        item.submenu = menu
        return item
    }

    private static func add(
        _ menu: NSMenu,
        _ title: String,
        _ action: Selector?,
        _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = .command,
        tag: Int = 0
    ) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.tag = tag
        menu.addItem(item)
    }

    private static func appMenu() -> NSMenuItem {
        submenu("MdEdit") { menu in
            add(menu, "About MdEdit", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
            menu.addItem(.separator())
            add(menu, "Settings…", #selector(AppDelegate.showPreferences(_:)), ",")
            menu.addItem(.separator())
            add(menu, "Hide MdEdit", #selector(NSApplication.hide(_:)), "h")
            add(menu, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
            add(menu, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
            menu.addItem(.separator())
            add(menu, "Quit MdEdit", #selector(NSApplication.terminate(_:)), "q")
        }
    }

    private static func fileMenu() -> NSMenuItem {
        submenu("File") { menu in
            add(menu, "New Tab", #selector(AppDelegate.newDocument(_:)), "t")
            add(menu, "New Window", #selector(AppDelegate.newWindow(_:)), "n")
            add(menu, "Open…", #selector(AppDelegate.openDocument(_:)), "o")
            add(menu, "Open Folder…", #selector(MainWindowController.openFolder(_:)), "o", [.command, .shift])
            add(menu, "Quick Open…", #selector(MainWindowController.quickOpen(_:)), "p")

            let recents = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
            let recentsMenu = NSMenu(title: "Open Recent")
            recentsMenu.perform(Selector(("_setMenuName:")), with: "NSRecentDocumentsMenu")
            recents.submenu = recentsMenu
            menu.addItem(recents)

            menu.addItem(.separator())
            add(menu, "Close Tab", #selector(MainWindowController.closeActiveTab(_:)), "w")
            add(menu, "Save", #selector(AppDelegate.saveDocument(_:)), "s")
            add(menu, "Save As…", #selector(AppDelegate.saveDocumentAs(_:)), "s", [.command, .shift])
            menu.addItem(submenu("Revert To") { revert in
                add(revert, "Last Saved", #selector(MainWindowController.revertToSaved(_:)))
                add(revert, "Browse Versions…", #selector(MainWindowController.browseVersions(_:)))
            })
            menu.addItem(.separator())
            menu.addItem(submenu("Export") { export in
                add(export, "HTML…", #selector(MainWindowController.exportHTML(_:)))
                add(export, "PDF…", #selector(MainWindowController.exportPDF(_:)))
                add(export, "Word Document…", #selector(MainWindowController.exportWord(_:)))
                add(export, "Rich Text…", #selector(MainWindowController.exportRichText(_:)))
                add(export, "Plain Text…", #selector(MainWindowController.exportPlainText(_:)))
                export.addItem(.separator())
                add(export, "With Pandoc…", #selector(MainWindowController.exportWithPandoc(_:)))
            })
            menu.addItem(.separator())
            add(menu, "Print…", #selector(MainWindowController.printDocument(_:)), "p", [.command, .option])
        }
    }

    private static func editMenu() -> NSMenuItem {
        submenu("Edit") { menu in
            add(menu, "Undo", Selector(("undo:")), "z")
            add(menu, "Redo", Selector(("redo:")), "z", [.command, .shift])
            menu.addItem(.separator())
            add(menu, "Cut", #selector(NSText.cut(_:)), "x")
            add(menu, "Copy", #selector(NSText.copy(_:)), "c")
            add(menu, "Paste", #selector(NSText.paste(_:)), "v")
            add(menu, "Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift])
            add(menu, "Copy as HTML", #selector(MainWindowController.copyAsHTML(_:)), "c", [.command, .shift])
            add(menu, "Copy as Rich Text", #selector(MainWindowController.copyAsRichText(_:)), "c", [.command, .option, .shift])
            add(menu, "Select All", #selector(NSText.selectAll(_:)), "a")
            menu.addItem(submenu("Selection") { selection in
                add(selection, "Add Next Occurrence", #selector(MainWindowController.addNextOccurrence(_:)), "d")
                add(selection, "Select All Occurrences", #selector(MainWindowController.selectAllOccurrences(_:)), "g", [.command, .control])
                selection.addItem(.separator())
                add(selection, "Add Caret Above", #selector(MainWindowController.addCaretAbove(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.control, .shift])
                add(selection, "Add Caret Below", #selector(MainWindowController.addCaretBelow(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.control, .shift])
            })
            menu.addItem(.separator())

            let find = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
            let findMenu = NSMenu(title: "Find")
            add(findMenu, "Find…", #selector(NSTextView.performFindPanelAction(_:)), "f", tag: NSTextFinder.Action.showFindInterface.rawValue)
            add(findMenu, "Find Next", #selector(NSTextView.performFindPanelAction(_:)), "g", tag: NSTextFinder.Action.nextMatch.rawValue)
            add(findMenu, "Find Previous", #selector(NSTextView.performFindPanelAction(_:)), "g", [.command, .shift], tag: NSTextFinder.Action.previousMatch.rawValue)
            add(findMenu, "Find and Replace…", #selector(NSTextView.performFindPanelAction(_:)), "f", [.command, .option], tag: NSTextFinder.Action.showReplaceInterface.rawValue)
            add(findMenu, "Use Selection for Find", #selector(NSTextView.performFindPanelAction(_:)), "e", tag: NSTextFinder.Action.setSearchString.rawValue)
            findMenu.addItem(.separator())
            add(findMenu, "Find in Folder…", #selector(MainWindowController.findInFolder(_:)), "f", [.command, .shift])
            find.submenu = findMenu
            menu.addItem(find)
        }
    }

    private static func formatMenu() -> NSMenuItem {
        submenu("Format") { menu in
            add(menu, "Bold", #selector(MainWindowController.toggleBold(_:)), "b")
            add(menu, "Italic", #selector(MainWindowController.toggleItalic(_:)), "i")
            add(menu, "Strikethrough", #selector(MainWindowController.toggleStrikethrough(_:)), "x", [.command, .shift])
            add(menu, "Inline Code", #selector(MainWindowController.toggleCode(_:)), "k", [.command, .shift])
            add(menu, "Link…", #selector(MainWindowController.insertLink(_:)), "k")
            menu.addItem(.separator())
            for level in 1...6 {
                add(menu, "Heading \(level)", #selector(MainWindowController.setHeadingLevel(_:)), "\(level)", [.command, .control], tag: level)
            }
            add(menu, "Paragraph", #selector(MainWindowController.setHeadingLevel(_:)), "0", [.command, .control], tag: 0)
            menu.addItem(.separator())
            add(menu, "Bulleted List", #selector(MainWindowController.toggleBulletList(_:)), "8", [.command, .shift])
            add(menu, "Numbered List", #selector(MainWindowController.toggleNumberedList(_:)), "7", [.command, .shift])
            add(menu, "Task List", #selector(MainWindowController.toggleTaskList(_:)), "9", [.command, .shift])
            add(menu, "Blockquote", #selector(MainWindowController.toggleQuote(_:)), "'", [.command, .shift])
            add(menu, "Code Block", #selector(MainWindowController.insertCodeBlock(_:)), "c", [.command, .option])
            add(menu, "Table of Contents", #selector(MainWindowController.insertTableOfContents(_:)))
            menu.addItem(.separator())
            menu.addItem(submenu("Table") { table in
                add(table, "Insert Table", #selector(MainWindowController.insertTable(_:)), "t", [.command, .option])
                table.addItem(.separator())
                add(table, "Add Row Above", #selector(MainWindowController.tableRowAbove(_:)))
                add(table, "Add Row Below", #selector(MainWindowController.tableRowBelow(_:)), "\r", [.command])
                add(table, "Delete Row", #selector(MainWindowController.tableDeleteRow(_:)))
                table.addItem(.separator())
                add(table, "Add Column Before", #selector(MainWindowController.tableColumnBefore(_:)))
                add(table, "Add Column After", #selector(MainWindowController.tableColumnAfter(_:)))
                add(table, "Delete Column", #selector(MainWindowController.tableDeleteColumn(_:)))
                table.addItem(.separator())
                add(table, "Align Column Left", #selector(MainWindowController.tableAlign(_:)), tag: 1)
                add(table, "Align Column Center", #selector(MainWindowController.tableAlign(_:)), tag: 2)
                add(table, "Align Column Right", #selector(MainWindowController.tableAlign(_:)), tag: 3)
                add(table, "Remove Column Alignment", #selector(MainWindowController.tableAlign(_:)), tag: 0)
                table.addItem(.separator())
                add(table, "Format Table", #selector(MainWindowController.tableFormat(_:)))
            })
        }
    }

    private static func viewMenu() -> NSMenuItem {
        submenu("View") { menu in
            add(menu, "Next Tab", #selector(MainWindowController.selectNextDocumentTab(_:)), "]", [.command, .shift])
            add(menu, "Previous Tab", #selector(MainWindowController.selectPreviousDocumentTab(_:)), "[", [.command, .shift])
            menu.addItem(.separator())
            add(menu, "Show Files", #selector(MainWindowController.toggleFiles(_:)), "e", [.command, .shift])
            add(menu, "Show Outline", #selector(MainWindowController.toggleOutline(_:)), "l", [.command, .shift])
            add(menu, "Statistics…", #selector(MainWindowController.showDocumentStatistics(_:)), "i", [.command, .shift])
            menu.addItem(.separator())
            add(menu, "Source Mode", #selector(MainWindowController.toggleSourceMode(_:)), "/")
            add(menu, "Typewriter Mode", #selector(MainWindowController.toggleTypewriterMode(_:)))
            add(menu, "Focus Mode", #selector(MainWindowController.toggleFocusMode(_:)))
            menu.addItem(.separator())
            add(menu, "Fold Section", #selector(MainWindowController.foldSection(_:)), String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.command, .option])
            add(menu, "Unfold Section", #selector(MainWindowController.unfoldSection(_:)), String(UnicodeScalar(NSRightArrowFunctionKey)!), [.command, .option])
            add(menu, "Fold All Sections", #selector(MainWindowController.foldAllSections(_:)), String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.command, .option, .control])
            add(menu, "Unfold All Sections", #selector(MainWindowController.unfoldAllSections(_:)), String(UnicodeScalar(NSRightArrowFunctionKey)!), [.command, .option, .control])
            menu.addItem(.separator())
            add(menu, "Actual Size", #selector(MainWindowController.resetZoom(_:)), "0")
            add(menu, "Zoom In", #selector(MainWindowController.zoomIn(_:)), "+")
            // ⌘= reaches Zoom In without Shift, as in every Mac app.
            let unshifted = NSMenuItem(title: "Zoom In", action: #selector(MainWindowController.zoomIn(_:)), keyEquivalent: "=")
            unshifted.isHidden = true
            unshifted.allowsKeyEquivalentWhenHidden = true
            menu.addItem(unshifted)
            add(menu, "Zoom Out", #selector(MainWindowController.zoomOut(_:)), "-")
            menu.addItem(.separator())
            add(menu, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        }
    }

    private static func windowMenu(app: NSApplication) -> NSMenuItem {
        let item = submenu("Window") { menu in
            add(menu, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
            add(menu, "Zoom", #selector(NSWindow.performZoom(_:)))
            menu.addItem(.separator())
            add(menu, "Move Tab to New Window", #selector(MainWindowController.moveTabToNewWindow(_:)))
            menu.addItem(.separator())
            add(menu, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        }
        app.windowsMenu = item.submenu
        return item
    }

    private static func helpMenu() -> NSMenuItem {
        let item = submenu("Help") { menu in
            add(menu, "MdEdit Help", #selector(AppDelegate.showHelp(_:)), "?")
        }
        return item
    }
}
