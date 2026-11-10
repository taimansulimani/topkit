import AppKit

/// Options for the standard About panel so the version line matches `AppVersionLabel.current`.
///
/// AppKit normally shows `Version <short> (<build>)`. We pass the full label as
/// `applicationVersion` and leave `version` empty so the build is not shown again in
/// parentheses on App Store copies (see TN2179: no build string → `Version` + marketing only).
enum StandardAboutPanel {
    static func options(versionLabel: String) -> [NSApplication.AboutPanelOptionKey: Any] {
        [
            .applicationVersion: versionLabel,
            .version: "",
        ]
    }

    static func present() {
        NSApp.orderFrontStandardAboutPanel(options: options(versionLabel: AppVersionLabel.current))
    }
}

final class StandardAboutPanelTarget: NSObject {
    static let shared = StandardAboutPanelTarget()

    @objc func showAboutPanel(_ sender: Any?) {
        StandardAboutPanel.present()
    }
}

/// The app's main menu: the application menu (About, Settings, Hide, Quit) plus an Edit menu with Cut, Copy,
/// Paste and Select All.
///
/// Topkit is a menu bar app (`LSUIElement`) started from `main.swift` with no nib, so
/// `NSApp.mainMenu` used to be nil. AppKit text fields have no ⌘A / ⌘C / ⌘V / ⌘X of
/// their own: the field editor only receives `selectAll:` / `copy:` / `paste:` / `cut:`
/// when a main-menu item with that key equivalent sends the action down the responder
/// chain. With no main menu the keystroke fell through to the field editor's `keyDown`,
/// matched no key binding and beeped, in the annotation text field and every other
/// text field in the app.
///
/// While the app is an accessory the menu is never on screen; AppKit still asks it for
/// key equivalents whenever Topkit is active. The key window's views are asked first,
/// so any view that handles one of these keys itself keeps doing so.
///
/// Deliberately not here:
/// - Undo / Redo: the annotation canvas owns ⌘Z through its own key monitor.
/// - Quit (⌘Q): one stray keystroke would quit mid-annotation and lose the marks.
enum StandardEditMenu {
    static let editMenuTitle = "Edit"

    static func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu(title: "Main Menu")

        // AppKit treats the first item as the application menu (titled with the app
        // name when the menu bar shows, e.g. while Preferences is open), so Edit must
        // not be first or its items would appear under "Topkit".
        let appItem = NSMenuItem(title: "Topkit", action: nil, keyEquivalent: "")
        appItem.submenu = makeApplicationMenu()
        mainMenu.addItem(appItem)

        let editMenu = NSMenu(title: editMenuTitle)
        // nil target: each action goes to the first responder, i.e. the field editor
        // of whichever text field is being typed in.
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

        let editItem = NSMenuItem(title: editMenuTitle, action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        return mainMenu
    }

    /// The standard application menu, so it is not empty while the menu bar shows.
    /// No key equivalents: ⌘Q or ⌘H mid-annotation would lose or hide the marks.
    static func makeApplicationMenu() -> NSMenu {
        let name = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "Topkit"
        let menu = NSMenu(title: name)
        let about = NSMenuItem(
            title: "About \(name)",
            action: #selector(StandardAboutPanelTarget.showAboutPanel(_:)),
            keyEquivalent: ""
        )
        about.target = StandardAboutPanelTarget.shared
        menu.addItem(about)
        menu.addItem(.separator())
        // AppDelegate.showPreferences, found through the responder chain (the app delegate).
        menu.addItem(NSMenuItem(title: "Settings…", action: NSSelectorFromString("showPreferences"), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        return menu
    }

    /// Call once at launch, before any text field can take focus.
    static func install(in app: NSApplication) {
        app.mainMenu = makeMainMenu()
    }
}
