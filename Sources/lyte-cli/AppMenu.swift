import AppKit
import LyteKit
import LyteUI

/// Main menu for the stream window. The CLI is unbundled, so without this the
/// menu bar keeps the launching app's identity (e.g. "iTerm2").
@MainActor
final class AppMenuController: NSObject, NSMenuItemValidation {
    private weak var window: NSWindow?
    private let session: LyteSession
    private let input: InputCapture
    private var muted = false
    private var floating = false
    private let streamSize: NSSize

    init(window: NSWindow, session: LyteSession, input: InputCapture, streamSize: NSSize) {
        self.window = window
        self.session = session
        self.input = input
        self.streamSize = streamSize
    }

    func install() {
        NSApp.applicationIconImage = AppIcon.shared   // Dock + About panel

        let main = NSMenu()

        // Application menu — the title only sticks for unbundled binaries when
        // set on the submenu after launch (AppKit otherwise shows argv[0]).
        let appMenu = NSMenu(title: "Lyte")
        appMenu.addItem(selfItem("About Lyte", #selector(about)))
        appMenu.addItem(.separator())
        appMenu.addItem(selfItem("Quit Lyte", #selector(quit), "q"))
        addSubmenu(appMenu, to: main)

        // Actions — everything useful, grouped: input / stream / window
        let actions = NSMenu(title: "Actions")
        actions.addItem(selfItem("Lock Mouse", #selector(toggleMouseLock), "l",
                                 modifiers: [.control, .option], tag: .mouseLock))
        actions.addItem(selfItem("Paste to Host", #selector(pasteToHost), "v"))
        actions.addItem(.separator())
        actions.addItem(selfItem("Refresh Video", #selector(refreshVideo), "r"))
        actions.addItem(selfItem("Mute Audio", #selector(toggleMute), "m",
                                 modifiers: [.command, .shift], tag: .mute))
        actions.addItem(.separator())
        actions.addItem(selfItem("Actual Size", #selector(actualSize), "0"))
        actions.addItem(selfItem("Float on Top", #selector(toggleFloat), "t",
                                 modifiers: [.command, .option], tag: .float))
        actions.addItem(chainItem("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f",
                                  modifiers: [.control, .command]))
        addSubmenu(actions, to: main)

        NSApp.mainMenu = main
    }

    // MARK: - Actions

    @objc private func about() {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineSpacing = 2
        let credits = NSAttributedString(
            string: "A Moonlight client for Sunshine hosts",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: style,
            ])
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationIcon: AppIcon.shared,
            .applicationName: "Lyte",
            .applicationVersion: "0.4 · Milestone 4",
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "© 2026 Steve Shreeve · GPL-3.0",
        ])
    }

    @objc private func quit() {
        window?.close()   // WindowCloser runs cleanup and exits
    }

    @objc private func pasteToHost() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        var chunk = ""
        for ch in text {
            if chunk.utf8.count + String(ch).utf8.count > 32 {
                if let p = InputPacket.utf8Text(chunk) {
                    session.sendInput(p, channel: InputPacket.channelUTF8)
                }
                chunk = ""
            }
            chunk.append(ch)
        }
        if let p = InputPacket.utf8Text(chunk) {
            session.sendInput(p, channel: InputPacket.channelUTF8)
        }
    }

    @objc private func toggleMouseLock() {
        input.toggleLock()
    }

    @objc private func refreshVideo() {
        session.requestIdr()
    }

    @objc private func toggleMute() {
        muted.toggle()
        session.setAudioMuted(muted)
    }

    /// Resize so one stream pixel = one device pixel (crispest possible image).
    @objc private func actualSize() {
        guard let window else { return }
        let scale = window.backingScaleFactor
        window.setContentSize(NSSize(width: streamSize.width / scale, height: streamSize.height / scale))
    }

    @objc private func toggleFloat() {
        guard let window else { return }
        floating.toggle()
        window.level = floating ? .floating : .normal
    }

    // MARK: - Validation (checkmarks + dynamic titles)

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch MenuTag(rawValue: menuItem.tag) ?? MenuTag.none {
        case .mouseLock:
            menuItem.title = input.locked ? "Release Mouse" : "Lock Mouse"
        case .mute:
            menuItem.state = muted ? .on : .off
        case .float:
            menuItem.state = floating ? .on : .off
        case .none:
            break
        }
        return true
    }

    // MARK: - Helpers

    private enum MenuTag: Int {
        case none = 0, mouseLock, mute, float
    }

    /// Item targeting this controller.
    private func selfItem(_ title: String, _ action: Selector, _ key: String = "",
                          modifiers: NSEvent.ModifierFlags = [.command],
                          tag: MenuTag = .none) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        item.tag = tag.rawValue
        return item
    }

    /// Item dispatched through the responder chain (nil target).
    private func chainItem(_ title: String, _ action: Selector, _ key: String = "",
                           modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private func addSubmenu(_ menu: NSMenu, to main: NSMenu) {
        let item = NSMenuItem()
        item.submenu = menu
        main.addItem(item)
    }
}
