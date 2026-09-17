import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let library = EmojiLibrary()
    let prefs = Preferences()
    let monitor = KeyboardMonitor()
    let hotKey = GlobalHotKey()
    let inline = InlineController()
    lazy var picker = PickerController(library: library, preferences: prefs)
    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    private var targetApp: NSRunningApplication?
    private var permissionTimer: Timer?
    private var preferenceWindow: NSWindow?
    private var accessLabel: NSTextField?
    private var accessWasTrusted = false
    private var observers: [NSObjectProtocol] = []
    private var outsideMonitor: Any?
    private var hotKeyRegistered = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "local.popmoji.app")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty { NSApp.terminate(nil); return }
        setupMenu()
        picker.onChoose = { [weak self] in self?.chooseFromPicker($0) }
        picker.onSettings = { [weak self] in self?.showPreferences() }
        picker.onClose = { [weak self] in self?.monitor.reset() }
        inline.onChoose = { [weak self] item in self?.commitInline(item: item) }
        monitor.enabled = { [weak self] in self?.prefs.autocomplete == true }
        monitor.excluded = { [weak self] id in self?.prefs.excludedApps.contains(id) == true }
        monitor.isPickerVisible = { [weak self] in self?.picker.panel.isVisible == true }
        monitor.inlineContains = { [weak self] point in
            guard let self, self.inline.panel.isVisible else { return false }
            let converted = NSPoint(x: point.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y)
            return self.inline.panel.frame.contains(converted)
        }
        monitor.onQuery = { [weak self] query in
            guard let self else { return }
            guard let query, !query.isEmpty else { self.inline.hide(); return }
            self.inline.show(query: query, results: self.library.search(query, aliases: self.prefs.aliases), tone: self.prefs.skinTone)
        }
        monitor.onNavigate = { [weak self] delta in self?.inline.navigate(delta) }
        monitor.onCommit = { [weak self] query in
            guard let self else { return false }
            let item = self.inline.query == query ? self.inline.selected : self.library.search(query, aliases: self.prefs.aliases).first
            guard let item else { return false }
            self.commitInline(item: item); return true
        }
        hotKey.action = { [weak self] in self?.togglePicker() }
        hotKeyRegistered = hotKey.register()
        monitor.start(); accessWasTrusted = Accessibility.trusted
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let trusted = Accessibility.trusted
            if trusted && !self.monitor.isRunning { self.monitor.start() }
            if !trusted && self.monitor.isRunning { self.monitor.stop() }
            if trusted != self.accessWasTrusted {
                self.accessWasTrusted = trusted; self.picker.refreshPermission(); self.updateAccessLabel()
            }
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            self.monitor.reset()
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
               app.processIdentifier != self.targetApp?.processIdentifier { self.picker.hide() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil, queue: .main) { [weak self] _ in self?.monitor.reset(); self?.picker.hide() })
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if self?.picker.panel.isVisible == true { self?.picker.hide() }
        }
        if !CommandLine.arguments.contains("--background") { showPicker() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPicker(); return true
    }
    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "face.smiling", accessibilityDescription: "Popmoji")
            button.toolTip = "Popmoji — emoji everywhere (⌃⌥Space)"
        }
        statusMenu = NSMenu(); statusMenu.delegate = self; statusItem.menu = statusMenu
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        addMenuItem("Open Popmoji                       ⌃⌥Space", action: #selector(openPickerMenu), to: menu)
        let autocomplete = addMenuItem("Autocomplete :shortcodes:", action: #selector(toggleAutocomplete), to: menu)
        autocomplete.state = prefs.autocomplete ? .on : .off
        let frontmost = NSWorkspace.shared.frontmostApplication
        if let app = frontmost, let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier {
            let excluded = prefs.excludedApps.contains(id)
            let item = addMenuItem("\(excluded ? "Enable" : "Disable") autocomplete in \(app.localizedName ?? id)", action: #selector(toggleExcluded(_:)), to: menu)
            item.representedObject = id
        }
        menu.addItem(.separator())
        addMenuItem("Preferences…", action: #selector(showPreferences), to: menu)
        if !Accessibility.trusted { addMenuItem("Enable Accessibility…", action: #selector(enableAccessibility), to: menu) }
        menu.addItem(.separator())
        let stats = NSMenuItem(title: "\(library.all.count) emoji · \(prefs.insertions) picks", action: nil, keyEquivalent: "")
        menu.addItem(stats)
        addMenuItem("Quit Popmoji", action: #selector(quit), to: menu)
    }
    @discardableResult private func addMenuItem(_ title: String, action: Selector, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item); return item
    }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func openPickerMenu() { showPicker() }
    @objc private func toggleAutocomplete() { prefs.autocomplete.toggle(); monitor.reset() }
    @objc private func enableAccessibility() { Accessibility.openSettings() }
    @objc private func toggleExcluded(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        if prefs.excludedApps.contains(id) { prefs.excludedApps.removeAll { $0 == id } }
        else { prefs.excludedApps.append(id) }
        monitor.reset()
    }
    private func togglePicker() { if picker.panel.isVisible { picker.hide() } else { showPicker() } }
    private func showPicker() {
        monitor.reset()
        let frontmost = NSWorkspace.shared.frontmostApplication
        targetApp = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : frontmost
        picker.show(targetName: targetApp?.localizedName)
    }
    private func chooseFromPicker(_ item: ContentItem) {
        picker.hide()
        if item.kind != .unicodeEmoji {
            let adapter = MacOSImageInsertionAdapter(resolver: BundledContentAssetResolver())
            guard let targetApp else { try? adapter.copy(item); return }
            adapter.insert(item, into: targetApp) { [weak self] success in
                if !success { self?.showInsertionFailure() }
            }
            return
        }
        guard let emoji = library.byName[item.name] else { return }
        let rendered = emoji.rendered(tone: prefs.skinTone)
        guard Accessibility.trusted, let targetApp else { Inserter.copy(rendered); prefs.record(emoji); return }
        Inserter.insert(rendered, into: targetApp) { [weak self] success in
            if success { self?.prefs.record(emoji) }
            else { self?.showInsertionFailure() }
        }
    }
    private func commitInline(item: Emoji) {
        guard let query = monitor.tracker.query, let pid = monitor.targetPID,
              let app = NSRunningApplication(processIdentifier: pid) else { monitor.reset(); return }
        let element = monitor.targetElement
        monitor.reset()
        Inserter.insert(item.rendered(tone: prefs.skinTone), into: app, replacing: ":" + query, originalElement: element) { [weak self] success in
            if success { self?.prefs.record(item) }
            else { NSSound.beep() }
        }
    }
    private func showInsertionFailure() {
        let alert = NSAlert(); alert.messageText = "The text field changed."
        alert.informativeText = "Put your cursor in the conversation and open Popmoji again. You can also use ⌘C in the picker to copy an emoji."
        alert.addButton(withTitle: "OK"); alert.runModal()
    }
    @objc func showPreferences() {
        picker.hide(); monitor.reset()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 570),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Popmoji Preferences"; window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let root = ColorView(frame: NSRect(x: 0, y: 0, width: 540, height: 570), color: Palette.paper)
        window.contentView = root
        label("Make it yours.", NSRect(x: 27, y: 24, width: 480, height: 35), in: root, size: 25, weight: .bold)
        label("A little more expression. A lot less searching.", NSRect(x: 29, y: 65, width: 475, height: 25), in: root, size: 13, color: Palette.muted)
        accessLabel = label("", NSRect(x: 29, y: 111, width: 350, height: 24), in: root, size: 13, weight: .semibold)
        updateAccessLabel()
        let access = ActionButton("Open Settings →", frame: NSRect(x: 372, y: 105, width: 140, height: 30)) { Accessibility.openSettings() }
        access.contentTintColor = Palette.purple; root.addSubview(access)
        label("Accessibility lets Popmoji insert emoji into your other apps.", NSRect(x: 29, y: 142, width: 480, height: 23), in: root, size: 12, color: Palette.muted)
        let autocomplete = NSButton(checkboxWithTitle: "Suggest emoji when I type :shortcodes:", target: self, action: #selector(setAutocomplete(_:)))
        autocomplete.frame = NSRect(x: 26, y: 185, width: 480, height: 27); autocomplete.state = prefs.autocomplete ? .on : .off
        root.addSubview(autocomplete)
        let login = NSButton(checkboxWithTitle: "Open Popmoji when I log in", target: self, action: #selector(setLogin(_:)))
        login.frame = NSRect(x: 26, y: 220, width: 480, height: 27); login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        root.addSubview(login)
        label("PICKER SHORTCUT", NSRect(x: 29, y: 274, width: 170, height: 20), in: root, size: 10, weight: .bold, color: Palette.muted)
        label(hotKeyRegistered ? "⌃⌥Space   ·   Control + Option + Space" : "Shortcut unavailable. Use the menu bar to open Popmoji.",
              NSRect(x: 29, y: 301, width: 480, height: 24), in: root, size: 14, weight: .medium)
        label("YOUR SHORTCUTS", NSRect(x: 29, y: 348, width: 480, height: 20), in: root, size: 10, weight: .bold, color: Palette.muted)
        let summary = prefs.aliases.isEmpty ? "Right-click an emoji in the picker to give it a custom alias." : prefs.aliases.sorted { $0.key < $1.key }.map { ":\($0.key):  →  \(library.byName[$0.value]?.emoji ?? $0.value)" }.joined(separator: "    ")
        let aliases = label(summary, NSRect(x: 29, y: 376, width: 480, height: 45), in: root, size: 12)
        aliases.maximumNumberOfLines = 2; aliases.lineBreakMode = .byWordWrapping
        let manage = ActionButton("Manage aliases…", frame: NSRect(x: 22, y: 423, width: 160, height: 28)) { [weak self] in self?.manageAliases() }
        manage.alignment = .left; manage.contentTintColor = Palette.purple; root.addSubview(manage)
        let exclusions = ActionButton("Excluded apps (\(prefs.excludedApps.count))…", frame: NSRect(x: 288, y: 423, width: 224, height: 28)) { [weak self] in self?.manageExclusions() }
        exclusions.contentTintColor = Palette.purple; root.addSubview(exclusions)
        root.addSubview(ColorView(frame: NSRect(x: 29, y: 479, width: 480, height: 1), color: Palette.line))
        label("Local by design. No account. No network requests.", NSRect(x: 29, y: 499, width: 480, height: 21), in: root, size: 12, weight: .medium)
        label("Only your favorites, aliases, and emoji picks are saved.", NSRect(x: 29, y: 525, width: 480, height: 19), in: root, size: 11, color: Palette.muted)
        preferenceWindow?.close(); preferenceWindow = window
        window.center(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    private func updateAccessLabel() {
        accessLabel?.stringValue = Accessibility.trusted ? (monitor.isRunning ? "●  Ready to insert everywhere" : "●  Accessibility enabled; reconnecting…") : "○  Accessibility is not enabled"
        accessLabel?.textColor = Accessibility.trusted ? Palette.purple : Palette.muted
    }
    @objc private func setAutocomplete(_ sender: NSButton) { prefs.autocomplete = sender.state == .on; monitor.reset() }
    @objc private func setLogin(_ sender: NSButton) {
        do {
            if sender.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
            let alert = NSAlert(); alert.messageText = "Login setting couldn't be changed"
            alert.informativeText = error.localizedDescription; alert.runModal()
        }
    }
    private func manageAliases() {
        let alert = NSAlert(); alert.messageText = "Your custom aliases"
        alert.informativeText = "Select an alias to remove it. Add aliases by right-clicking an emoji in the picker."
        alert.addButton(withTitle: "Remove Selected"); alert.addButton(withTitle: "Done")
        let dropdown = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 340, height: 28))
        let keys = prefs.aliases.keys.sorted()
        dropdown.addItems(withTitles: keys.isEmpty ? ["No custom aliases yet"] : keys.map { ":\($0):  →  \(library.byName[prefs.aliases[$0] ?? ""]?.emoji ?? "")" })
        alert.accessoryView = dropdown; alert.buttons.first?.isEnabled = !keys.isEmpty
        if alert.runModal() == .alertFirstButtonReturn, keys.indices.contains(dropdown.indexOfSelectedItem) {
            prefs.aliases.removeValue(forKey: keys[dropdown.indexOfSelectedItem]); showPreferences()
        }
    }
    private func manageExclusions() {
        let alert = NSAlert(); alert.messageText = "Apps without autocomplete"
        alert.informativeText = "To exclude an app, switch to it, then choose Disable autocomplete in that app from Popmoji's menu bar icon. The floating picker remains available."
        alert.addButton(withTitle: "Enable Selected App"); alert.addButton(withTitle: "Done")
        let dropdown = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 340, height: 28))
        dropdown.addItems(withTitles: prefs.excludedApps.isEmpty ? ["No excluded apps"] : prefs.excludedApps)
        alert.accessoryView = dropdown; alert.buttons.first?.isEnabled = !prefs.excludedApps.isEmpty
        if alert.runModal() == .alertFirstButtonReturn, prefs.excludedApps.indices.contains(dropdown.indexOfSelectedItem) {
            prefs.excludedApps.remove(at: dropdown.indexOfSelectedItem); showPreferences()
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop(); permissionTimer?.invalidate()
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
    }
}
