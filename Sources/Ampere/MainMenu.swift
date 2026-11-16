import AppKit

// MARK: - Links

/// Where the app's own links lead. The About sheet and the Help menu show
/// the same ones.
enum AmpereLinks {
    static let website = URL(string: "https://amperebattery.app/")!
    /// "How Ampere works", the product site's documentation.
    static let help = URL(string: "https://amperebattery.app/tech.html")!
    /// With its extension: the extensionless path 404s on the server.
    static let changelog = URL(string: "https://amperebattery.app/changelog.html")!
    static let support = URL(string: "https://azcode.dev/")!
}

// MARK: - Main Menu

/// The app's menu bar. Unseen for as long as Ampere is a menu bar app (an
/// accessory app shows no menus of its own), but live even then for its key
/// equivalents: Cmd+, Cmd+W, Cmd+Q, and the Edit commands the registration
/// window's fields answer to. It shows once the panel is torn off into a
/// window, which makes Ampere a regular app for as long as that window is
/// open (AppDelegate.setRegularApp).
///
/// It used to come from a SwiftUI scene that was never shown (a Settings
/// scene around an EmptyView), kept for the menu alone. That menu could not
/// be shaped: it had a View menu with nothing in it, a Help item that
/// answered "Help isn't available", and an About item that opened the
/// system's panel instead of the app's own (dumped from a scratch app,
/// 2026-11-15). Every window was AppKit's already, so the scene went and the
/// menu is AppKit's too.
///
/// AppKit fills in the rest: the Services submenu, the open windows under
/// Window, the search field in Help, and AutoFill, Dictation and Emoji &
/// Symbols under Edit.
enum MainMenu {
    /// The menu bar and the three submenus AppKit wants to know by name.
    struct Menus {
        let main: NSMenu
        let services: NSMenu
        let window: NSMenu
        let help: NSMenu
    }

    /// Build the menu and hand it to the app.
    static func install(for delegate: AppDelegate) {
        let menus = build(for: delegate)
        NSApp.mainMenu = menus.main
        NSApp.servicesMenu = menus.services
        NSApp.windowsMenu = menus.window
        NSApp.helpMenu = menus.help
    }

    /// The menu as it is installed. Apart from `install` so a test can read
    /// it without an app to hand it to. Items whose action is the app's own
    /// carry `delegate` as their target; the standard ones go down the
    /// responder chain, which is what disables Copy where nothing is
    /// selected and Minimize where no window has the keyboard.
    static func build(for delegate: AppDelegate) -> Menus {
        let main = NSMenu()

        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            item.submenu = menu
            main.addItem(item)
            return menu
        }

        @discardableResult
        func add(_ menu: NSMenu, _ title: String, _ action: Selector?, key: String = "",
                 modifiers: NSEvent.ModifierFlags = .command, own: Bool = false) -> NSMenuItem {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            if own { item.target = delegate }
            return item
        }

        func link(_ menu: NSMenu, _ title: String, _ url: URL, key: String = "") {
            add(menu, title, #selector(AppDelegate.openLink(_:)), key: key, own: true).representedObject = url
        }

        // The application menu. macOS titles it with the app's name
        // whatever this one says.
        let app = submenu("Ampere")
        add(app, "About Ampere", #selector(AppDelegate.showAbout(_:)), own: true)
        app.addItem(.separator())
        add(app, "Settings…", #selector(AppDelegate.showSettings(_:)), key: ",", own: true)
        app.addItem(.separator())
        let services = NSMenu(title: "Services")
        add(app, "Services", nil).submenu = services
        app.addItem(.separator())
        add(app, "Hide Ampere", #selector(NSApplication.hide(_:)), key: "h")
        add(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), key: "h",
            modifiers: [.command, .option])
        add(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator())
        add(app, "Quit Ampere", #selector(NSApplication.terminate(_:)), key: "q")

        // Close is the app's own: the attached panel is a popover, which
        // the standard performClose: does not close (AppDelegate.closeKeyWindow).
        let file = submenu("File")
        add(file, "Close Window", #selector(AppDelegate.closeKeyWindow(_:)), key: "w", own: true)

        let edit = submenu("Edit")
        add(edit, "Undo", Selector(("undo:")), key: "z")
        add(edit, "Redo", Selector(("redo:")), key: "z", modifiers: [.command, .shift])
        edit.addItem(.separator())
        add(edit, "Cut", #selector(NSText.cut(_:)), key: "x")
        add(edit, "Copy", #selector(NSText.copy(_:)), key: "c")
        add(edit, "Paste", #selector(NSText.paste(_:)), key: "v")
        add(edit, "Delete", #selector(NSText.delete(_:)))
        add(edit, "Select All", #selector(NSText.selectAll(_:)), key: "a")

        // No Zoom: none of the app's windows can be resized, so it would
        // never be enabled.
        let window = submenu("Window")
        add(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m")
        window.addItem(.separator())
        add(window, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))

        let help = submenu("Help")
        link(help, "Ampere Help", AmpereLinks.help, key: "?")
        help.addItem(.separator())
        link(help, "Ampere Website", AmpereLinks.website)
        link(help, "Changelog", AmpereLinks.changelog)
        link(help, "Support", AmpereLinks.support)

        return Menus(main: main, services: services, window: window, help: help)
    }
}
