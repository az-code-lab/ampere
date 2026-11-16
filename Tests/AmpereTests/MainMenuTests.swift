import XCTest
import AppKit
@testable import Ampere

/// The menu bar (MainMenu). It shows while the panel is a window and is
/// live for its shortcuts at all times, so its shape is pinned here: which
/// menus there are, what each command is called, which keys it answers to
/// and who gets it. Built without an app to install it in.
final class MainMenuTests: XCTestCase {
    private var delegate: AppDelegate!
    private var menus: MainMenu.Menus!

    override func setUp() {
        super.setUp()
        delegate = AppDelegate()
        menus = MainMenu.build(for: delegate)
    }

    override func tearDown() {
        menus = nil
        delegate = nil
        super.tearDown()
    }

    private func menu(_ title: String) throws -> NSMenu {
        try XCTUnwrap(menus.main.items.first { $0.title == title }?.submenu, "no \(title) menu")
    }

    private func item(_ menuTitle: String, _ title: String) throws -> NSMenuItem {
        try XCTUnwrap(try menu(menuTitle).items.first { $0.title == title }, "no \(title) in \(menuTitle)")
    }

    private func titles(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "-" : $0.title }
    }

    private func shortcut(_ item: NSMenuItem) -> String {
        guard !item.keyEquivalent.isEmpty else { return "" }
        var text = ""
        if item.keyEquivalentModifierMask.contains(.option) { text += "opt+" }
        if item.keyEquivalentModifierMask.contains(.shift) { text += "shift+" }
        if item.keyEquivalentModifierMask.contains(.command) { text += "cmd+" }
        return text + item.keyEquivalent
    }

    /// The SwiftUI scene this replaced came with a View menu that had
    /// nothing in it (2026-11-15). Every menu here has something to offer.
    func testTheMenusAndNoneOfThemEmpty() throws {
        XCTAssertEqual(menus.main.items.map(\.title), ["Ampere", "File", "Edit", "Window", "Help"])
        for item in menus.main.items {
            XCTAssertFalse(try XCTUnwrap(item.submenu).items.isEmpty, "\(item.title) is empty")
        }
    }

    func testWhatEachMenuHolds() throws {
        XCTAssertEqual(titles(try menu("Ampere")),
                       ["About Ampere", "-", "Settings…", "-", "Services", "-",
                        "Hide Ampere", "Hide Others", "Show All", "-", "Quit Ampere"])
        XCTAssertEqual(titles(try menu("File")), ["Close Window"])
        XCTAssertEqual(titles(try menu("Edit")),
                       ["Undo", "Redo", "-", "Cut", "Copy", "Paste", "Delete", "Select All"])
        XCTAssertEqual(titles(try menu("Window")), ["Minimize", "-", "Bring All to Front"])
        XCTAssertEqual(titles(try menu("Help")), ["Ampere Help", "-", "Ampere Website", "Changelog", "Support"])
    }

    func testTheShortcuts() throws {
        XCTAssertEqual(shortcut(try item("Ampere", "Settings…")), "cmd+,")
        XCTAssertEqual(shortcut(try item("Ampere", "Hide Ampere")), "cmd+h")
        XCTAssertEqual(shortcut(try item("Ampere", "Hide Others")), "opt+cmd+h")
        XCTAssertEqual(shortcut(try item("Ampere", "Quit Ampere")), "cmd+q")
        XCTAssertEqual(shortcut(try item("File", "Close Window")), "cmd+w")
        XCTAssertEqual(shortcut(try item("Edit", "Undo")), "cmd+z")
        XCTAssertEqual(shortcut(try item("Edit", "Redo")), "shift+cmd+z")
        XCTAssertEqual(shortcut(try item("Edit", "Cut")), "cmd+x")
        XCTAssertEqual(shortcut(try item("Edit", "Copy")), "cmd+c")
        XCTAssertEqual(shortcut(try item("Edit", "Paste")), "cmd+v")
        XCTAssertEqual(shortcut(try item("Edit", "Select All")), "cmd+a")
        XCTAssertEqual(shortcut(try item("Window", "Minimize")), "cmd+m")
        XCTAssertEqual(shortcut(try item("Help", "Ampere Help")), "cmd+?")
        // The ones with none.
        for (menu, title) in [("Ampere", "About Ampere"), ("Ampere", "Show All"), ("Edit", "Delete"),
                              ("Window", "Bring All to Front"), ("Help", "Changelog")] {
            XCTAssertEqual(shortcut(try item(menu, title)), "", "\(title)")
        }
    }

    func testNoTwoCommandsShareAShortcut() {
        let all = menus.main.items.flatMap { $0.submenu?.items ?? [] }.map(shortcut).filter { !$0.isEmpty }
        XCTAssertEqual(all.count, Set(all).count, "\(all)")
    }

    /// The app's own commands carry the delegate as their target, and the
    /// delegate answers each of them: a selector it lost would leave a dead
    /// item behind, with nothing to say so at build time.
    func testTheAppsOwnCommandsGoToTheDelegate() throws {
        let own = [try item("Ampere", "About Ampere"), try item("Ampere", "Settings…"),
                   try item("File", "Close Window")] + (try menu("Help")).items.filter { !$0.isSeparatorItem }
        for item in own {
            XCTAssertTrue(item.target === delegate, "\(item.title)")
            let action = try XCTUnwrap(item.action, "\(item.title)")
            XCTAssertTrue(delegate.responds(to: action), "\(item.title)")
        }
        XCTAssertEqual(try item("Ampere", "About Ampere").action, #selector(AppDelegate.showAbout(_:)))
        XCTAssertEqual(try item("Ampere", "Settings…").action, #selector(AppDelegate.showSettings(_:)))
        XCTAssertEqual(try item("File", "Close Window").action, #selector(AppDelegate.closeKeyWindow(_:)))
    }

    /// The standard commands have no target: they go to whatever has the
    /// keyboard, which is what disables Copy with nothing selected and
    /// Minimize with no window to minimize.
    func testTheStandardCommandsGoDownTheResponderChain() throws {
        let standard: [(String, String, Selector)] = [
            ("Ampere", "Hide Ampere", #selector(NSApplication.hide(_:))),
            ("Ampere", "Hide Others", #selector(NSApplication.hideOtherApplications(_:))),
            ("Ampere", "Show All", #selector(NSApplication.unhideAllApplications(_:))),
            ("Ampere", "Quit Ampere", #selector(NSApplication.terminate(_:))),
            ("Edit", "Undo", Selector(("undo:"))),
            ("Edit", "Redo", Selector(("redo:"))),
            ("Edit", "Cut", #selector(NSText.cut(_:))),
            ("Edit", "Copy", #selector(NSText.copy(_:))),
            ("Edit", "Paste", #selector(NSText.paste(_:))),
            ("Edit", "Delete", #selector(NSText.delete(_:))),
            ("Edit", "Select All", #selector(NSText.selectAll(_:))),
            ("Window", "Minimize", #selector(NSWindow.performMiniaturize(_:))),
            ("Window", "Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ]
        for (menu, title, action) in standard {
            let item = try item(menu, title)
            XCTAssertNil(item.target, title)
            XCTAssertEqual(item.action, action, title)
        }
    }

    func testTheHelpMenuLeadsToTheAppsPages() throws {
        func link(_ title: String) throws -> URL {
            let item = try item("Help", title)
            XCTAssertEqual(item.action, #selector(AppDelegate.openLink(_:)), title)
            return try XCTUnwrap(item.representedObject as? URL, title)
        }
        XCTAssertEqual(try link("Ampere Help"), AmpereLinks.help)
        XCTAssertEqual(try link("Ampere Website"), AmpereLinks.website)
        XCTAssertEqual(try link("Changelog"), AmpereLinks.changelog)
        XCTAssertEqual(try link("Support"), AmpereLinks.support)
        XCTAssertEqual(AmpereLinks.help.absoluteString, "https://amperebattery.app/tech.html")
        // With its extension: the extensionless path answers 404.
        XCTAssertEqual(AmpereLinks.changelog.absoluteString, "https://amperebattery.app/changelog.html")
    }

    /// AppKit fills in three submenus by itself (the services, the open
    /// windows, the Help search field) and has to be told which they are.
    func testTheSubmenusAppKitFillsInAreTheOnesInTheBar() throws {
        XCTAssertTrue(try item("Ampere", "Services").submenu === menus.services)
        XCTAssertTrue(try menu("Window") === menus.window)
        XCTAssertTrue(try menu("Help") === menus.help)
    }

    /// About Ampere opens the About sheet of the panel's window, so it is
    /// offered only while the panel is a window; a delegate that has not
    /// opened one answers no.
    func testAboutIsOfferedOnlyWhileThePanelIsAWindow() throws {
        XCTAssertFalse(delegate.validateMenuItem(try item("Ampere", "About Ampere")))
        // Settings… is always there: with no license it leads to the registration window.
        XCTAssertTrue(delegate.validateMenuItem(try item("Ampere", "Settings…")))
    }
}
