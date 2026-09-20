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
            add(menu, "Open…", #selector(AppDelegate.openDocument(_:)), "o")

            let recents = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
            let recentsMenu = NSMenu(title: "Open Recent")
            recentsMenu.perform(Selector(("_setMenuName:")), with: "NSRecentDocumentsMenu")
            recents.submenu = recentsMenu
            menu.addItem(recents)

            menu.addItem(.separator())
            add(menu, "Close Tab", #selector(MainWindowController.closeActiveTab(_:)), "w")
            add(menu, "Save", #selector(AppDelegate.saveDocument(_:)), "s")
            add(menu, "Save As…", #selector(AppDelegate.saveDocumentAs(_:)), "s", [.command, .shift])
            menu.addItem(.separator())
            add(menu, "Export as HTML…", #selector(MainWindowController.exportHTML(_:)))
            add(menu, "Export as PDF…", #selector(MainWindowController.exportPDF(_:)))
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
            add(menu, "Select All", #selector(NSText.selectAll(_:)), "a")
            menu.addItem(.separator())

            let find = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
            let findMenu = NSMenu(title: "Find")
            add(findMenu, "Find…", #selector(NSTextView.performFindPanelAction(_:)), "f", tag: NSTextFinder.Action.showFindInterface.rawValue)
            add(findMenu, "Find Next", #selector(NSTextView.performFindPanelAction(_:)), "g", tag: NSTextFinder.Action.nextMatch.rawValue)
            add(findMenu, "Find Previous", #selector(NSTextView.performFindPanelAction(_:)), "g", [.command, .shift], tag: NSTextFinder.Action.previousMatch.rawValue)
            add(findMenu, "Find and Replace…", #selector(NSTextView.performFindPanelAction(_:)), "f", [.command, .option], tag: NSTextFinder.Action.showReplaceInterface.rawValue)
            add(findMenu, "Use Selection for Find", #selector(NSTextView.performFindPanelAction(_:)), "e", tag: NSTextFinder.Action.setSearchString.rawValue)
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
        }
    }

    private static func viewMenu() -> NSMenuItem {
        submenu("View") { menu in
            add(menu, "Next Tab", #selector(MainWindowController.selectNextDocumentTab(_:)), "]", [.command, .shift])
            add(menu, "Previous Tab", #selector(MainWindowController.selectPreviousDocumentTab(_:)), "[", [.command, .shift])
            menu.addItem(.separator())
            add(menu, "Typewriter Mode", #selector(MainWindowController.toggleTypewriterMode(_:)))
            add(menu, "Focus Mode", #selector(MainWindowController.toggleFocusMode(_:)))
            menu.addItem(.separator())
            add(menu, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        }
    }

    private static func windowMenu(app: NSApplication) -> NSMenuItem {
        let item = submenu("Window") { menu in
            add(menu, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
            add(menu, "Zoom", #selector(NSWindow.performZoom(_:)))
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
