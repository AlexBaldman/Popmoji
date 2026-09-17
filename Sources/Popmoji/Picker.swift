import AppKit

enum Palette {
    static let ink = NSColor(srgbRed: 0.12, green: 0.14, blue: 0.19, alpha: 1)
    static let muted = NSColor(srgbRed: 0.46, green: 0.47, blue: 0.51, alpha: 1)
    static let paper = NSColor(srgbRed: 0.985, green: 0.976, blue: 0.956, alpha: 1)
    static let purple = NSColor(srgbRed: 0.43, green: 0.32, blue: 0.91, alpha: 1)
    static let lavender = NSColor(srgbRed: 0.91, green: 0.88, blue: 0.99, alpha: 1)
    static let line = NSColor(srgbRed: 0.89, green: 0.88, blue: 0.87, alpha: 1)
}

class FlippedView: NSView { override var isFlipped: Bool { true } }
final class ColorView: FlippedView {
    init(frame: NSRect, color: NSColor, radius: CGFloat = 0) {
        super.init(frame: frame); wantsLayer = true
        layer?.backgroundColor = color.cgColor; layer?.cornerRadius = radius
    }
    required init?(coder: NSCoder) { fatalError() }
}
@discardableResult func label(_ text: String, _ frame: NSRect, in view: NSView,
                              size: CGFloat = 13, weight: NSFont.Weight = .regular,
                              color: NSColor = Palette.ink) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.frame = frame; field.font = .systemFont(ofSize: size, weight: weight); field.textColor = color
    field.lineBreakMode = .byTruncatingTail
    view.addSubview(field); return field
}
final class ActionButton: NSButton {
    var handler: (() -> Void)?
    init(_ title: String, frame: NSRect, handler: @escaping () -> Void) {
        super.init(frame: frame); self.title = title; self.handler = handler
        target = self; action = #selector(invoke); isBordered = false
        font = .systemFont(ofSize: 12, weight: .medium)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func invoke() { handler?() }
}

final class EmojiTile: NSButton {
    let item: ContentItem
    let image: NSImage?
    var rendered: String
    var selected = false { didSet { needsDisplay = true } }
    var favorite = false { didSet { needsDisplay = true } }
    var onChoose: (() -> Void)?
    var onHover: (() -> Void)?
    var onFavorite: (() -> Void)?
    var onAlias: (() -> Void)?
    init(item: ContentItem, rendered: String, image: NSImage?, frame: NSRect) {
        self.item = item; self.rendered = rendered; self.image = image
        super.init(frame: frame)
        isBordered = false; title = ""; target = self; action = #selector(choose)
        toolTip = "\(item.description)  :\(item.name):"
        setAccessibilityLabel(item.altText)
        setAccessibilityHelp("Insert :\(item.name):. Right-click for favorites and custom aliases.")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        if selected || isHighlighted {
            Palette.lavender.setFill(); NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 12, yRadius: 12).fill()
        }
        if let image {
            image.draw(in: bounds.insetBy(dx: 11, dy: 8), from: .zero, operation: .sourceOver, fraction: 1)
        } else {
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont(name: "Apple Color Emoji", size: 29) ?? NSFont.systemFont(ofSize: 29)]
            let size = (rendered as NSString).size(withAttributes: attributes)
            (rendered as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
        }
        if favorite {
            Palette.purple.setFill(); NSBezierPath(ovalIn: NSRect(x: bounds.maxX - 9, y: 5, width: 4, height: 4)).fill()
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let favoriteItem = NSMenuItem(title: favorite ? "Remove from Favorites" : "Add to Favorites", action: #selector(toggleFavorite), keyEquivalent: "")
        favoriteItem.target = self; menu.addItem(favoriteItem)
        let aliasItem = NSMenuItem(title: "Set Custom Alias…", action: #selector(addAlias), keyEquivalent: "")
        aliasItem.target = self; menu.addItem(aliasItem)
        return menu
    }
    @objc private func choose() { onChoose?() }
    @objc private func toggleFavorite() { onFavorite?() }
    @objc private func addAlias() { onAlias?() }
}

final class PickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class PickerController: NSObject, NSSearchFieldDelegate {
    let panel: PickerPanel
    private let library: EmojiLibrary
    private let prefs: Preferences
    private let catalog: ContentCatalog
    private let assetResolver = BundledContentAssetResolver()
    var onChoose: ((ContentItem) -> Void)?
    var onSettings: (() -> Void)?
    var onClose: (() -> Void)?
    private var search: NSSearchField!
    private var scroll: NSScrollView!
    private var grid = FlippedView()
    private var sectionLabel: NSTextField!
    private var countLabel: NSTextField!
    private var nameLabel: NSTextField!
    private var shortcodeLabel: NSTextField!
    private var statusLabel: NSTextField!
    private var largeEmoji: NSTextField!
    private var favoriteButton: ActionButton!
    private var toneButton: ActionButton!
    private var accessBanner: NSView!
    private var sidebarButtons: [String: ActionButton] = [:]
    private var tiles: [EmojiTile] = []
    private var results: [ContentItem] = []
    private var selected = 0
    private var category = "For you"
    private var keyMonitor: Any?
    private var targetName: String?
    private var lastTrusted = false
    private let columns = 8

    init(library: EmojiLibrary, preferences: Preferences) {
        self.library = library; prefs = preferences
        catalog = try! ContentCatalog(providers: [
            UnicodeEmojiProvider(library: library),
            BundledContentPackProvider(manifestName: "pickleball")
        ])
        panel = PickerPanel(contentRect: NSRect(x: 0, y: 0, width: 740, height: 570),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.title = "Popmoji"; panel.level = .floating; panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.hasShadow = true; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .aqua)
        buildUI()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow, event.window == self.panel else { return event }
            if event.modifierFlags.contains(.command) {
                switch event.charactersIgnoringModifiers {
                case "c" where self.search.currentEditor()?.selectedRange.length == 0:
                    self.copySelected(); return nil
                case "d": self.toggleSelectedFavorite(); return nil
                case "w": self.hide(); return nil
                default: return event
                }
            }
            switch event.keyCode {
            case 53: self.hide(); return nil
            case 125: self.move(self.columns); return nil
            case 126: self.move(-self.columns); return nil
            case 123 where self.search.stringValue.isEmpty: self.move(-1); return nil
            case 124 where self.search.stringValue.isEmpty: self.move(1); return nil
            case 36, 76: self.chooseSelected(); return nil
            default: return event
            }
        }
    }
    private func buildUI() {
        let root = ColorView(frame: NSRect(x: 0, y: 0, width: 740, height: 570), color: Palette.paper, radius: 18)
        root.layer?.masksToBounds = true; panel.contentView = root
        let sidebar = ColorView(frame: NSRect(x: 0, y: 0, width: 166, height: 570), color: Palette.ink)
        root.addSubview(sidebar)
        label("✳", NSRect(x: 18, y: 25, width: 29, height: 33), in: sidebar, size: 29, weight: .bold, color: NSColor(srgbRed: 0.76, green: 0.69, blue: 1, alpha: 1))
        label("Popmoji", NSRect(x: 49, y: 32, width: 104, height: 27), in: sidebar, size: 19, weight: .bold, color: .white)
        label("A LITTLE MORE YOU.", NSRect(x: 19, y: 71, width: 135, height: 15), in: sidebar, size: 9, weight: .semibold, color: .init(white: 0.64, alpha: 1))
        var choices = [("For you", "✦", "For you"), ("Favorites", "♡", "Favorites"), ("Recent", "◷", "Recent"), ("All emoji", "⊞", "All emoji")]
        let icons = ["Smileys & Emotion": "☺", "People & Body": "☝", "Animals & Nature": "❀", "Food & Drink": "♨", "Travel & Places": "✈", "Activities": "⚽", "Objects": "♬", "Symbols": "♥", "Flags": "⚑"]
        let shortNames = ["Smileys & Emotion": "Smileys", "People & Body": "People", "Animals & Nature": "Nature", "Food & Drink": "Food & drink", "Travel & Places": "Travel"]
        choices += library.categories.map { ($0, icons[$0] ?? "•", shortNames[$0] ?? $0) }
        for (index, choice) in choices.enumerated() {
            let button = ActionButton("\(choice.1)   \(choice.2)", frame: NSRect(x: 10, y: 107 + index * 30, width: 145, height: 28)) { [weak self] in
                self?.category = choice.0; self?.search.stringValue = ""; self?.refresh()
            }
            button.alignment = .left; button.contentTintColor = .init(white: 0.76, alpha: 1)
            button.wantsLayer = true; button.layer?.cornerRadius = 7
            sidebar.addSubview(button); sidebarButtons[choice.0] = button
        }
        let settings = ActionButton("⚙   Preferences", frame: NSRect(x: 16, y: 526, width: 140, height: 28)) { [weak self] in self?.onSettings?() }
        settings.alignment = .left; settings.contentTintColor = .init(white: 0.7, alpha: 1); sidebar.addSubview(settings)

        search = NSSearchField(frame: NSRect(x: 188, y: 25, width: 490, height: 42))
        search.placeholderString = "Find the feeling. Try happy, coffee, or party…"
        search.font = .systemFont(ofSize: 14); search.delegate = self
        search.sendsSearchStringImmediately = true; search.focusRingType = .none
        search.setAccessibilityLabel("Search emoji")
        root.addSubview(search)
        let close = ActionButton("×", frame: NSRect(x: 691, y: 30, width: 29, height: 29)) { [weak self] in self?.hide() }
        close.font = .systemFont(ofSize: 22); close.contentTintColor = Palette.muted
        close.setAccessibilityLabel("Close picker"); root.addSubview(close)
        sectionLabel = label("For you", NSRect(x: 190, y: 88, width: 245, height: 24), in: root, size: 18, weight: .bold)
        countLabel = label("", NSRect(x: 440, y: 95, width: 164, height: 17), in: root, size: 11, color: Palette.muted)
        countLabel.alignment = .right
        toneButton = ActionButton("✋  ▾", frame: NSRect(x: 624, y: 83, width: 90, height: 31)) { [weak self] in self?.showTones() }
        toneButton.setAccessibilityLabel("Choose skin tone"); root.addSubview(toneButton)
        scroll = NSScrollView(frame: NSRect(x: 184, y: 128, width: 538, height: 374))
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.documentView = grid; root.addSubview(scroll)
        accessBanner = ColorView(frame: NSRect(x: 191, y: 447, width: 521, height: 55), color: Palette.lavender, radius: 10)
        root.addSubview(accessBanner)
        label("Make it work everywhere", NSRect(x: 12, y: 8, width: 290, height: 19), in: accessBanner, size: 12, weight: .semibold)
        label("Enable Accessibility to insert into your apps.", NSRect(x: 12, y: 28, width: 320, height: 18), in: accessBanner, size: 11, color: Palette.muted)
        let enable = ActionButton("Enable →", frame: NSRect(x: 409, y: 13, width: 100, height: 30)) { Accessibility.openSettings() }
        enable.contentTintColor = Palette.purple; accessBanner.addSubview(enable)
        let line = ColorView(frame: NSRect(x: 166, y: 515, width: 574, height: 1), color: Palette.line); root.addSubview(line)
        largeEmoji = label("", NSRect(x: 188, y: 526, width: 40, height: 34), in: root, size: 27)
        nameLabel = label("", NSRect(x: 238, y: 524, width: 280, height: 19), in: root, size: 12, weight: .semibold)
        shortcodeLabel = label("", NSRect(x: 238, y: 545, width: 280, height: 16), in: root, size: 10, color: Palette.muted)
        favoriteButton = ActionButton("♡", frame: NSRect(x: 520, y: 528, width: 31, height: 27)) { [weak self] in self?.toggleSelectedFavorite() }
        favoriteButton.font = .systemFont(ofSize: 23); favoriteButton.contentTintColor = Palette.purple
        favoriteButton.setAccessibilityLabel("Toggle favorite"); root.addSubview(favoriteButton)
        statusLabel = label("↵ insert  ·  esc close", NSRect(x: 559, y: 537, width: 163, height: 19), in: root, size: 10, color: Palette.muted)
        statusLabel.alignment = .right
    }
    func show(targetName: String?) {
        self.targetName = targetName
        search.stringValue = ""; category = "For you"
        refreshPermission(); refresh()
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        if let screen {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2 + 40))
        }
        panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(search)
    }
    func hide() { panel.orderOut(nil); onClose?() }
    func refreshPermission() {
        lastTrusted = Accessibility.trusted
        accessBanner.isHidden = lastTrusted
        scroll.setFrameSize(NSSize(width: 538, height: lastTrusted ? 374 : 309))
        updateFooter()
    }
    func controlTextDidChange(_ obj: Notification) { refresh() }
    func refresh() {
        let source: [ContentItem]
        switch category {
        case "Favorites": source = prefs.favorites.compactMap { library.byName[$0]?.contentItem }
        case "Recent": source = prefs.recents.compactMap { library.byName[$0]?.contentItem }
        case "For you":
            let defaults = ["wave", "sparkles", "heart", "joy", "fire", "rocket", "+1", "tada", "eyes", "thinking", "sob", "laughing", "100", "pray", "clap", "muscle", "sunglasses", "heart_eyes", "blush", "wink", "upside_down_face", "melting_face", "coffee", "pizza", "sunny", "rainbow", "star", "white_check_mark", "brain", "seedling", "partying_face", "handshake", "grin", "smiling_face_with_three_hearts", "ok_hand", "v", "raised_hands", "cat", "dog", "butterfly", "ocean", "earth_americas", "balloon", "birthday", "musical_note", "bulb", "gem", "speech_balloon"]
            var seen = Set<String>()
            source = (prefs.recents.prefix(16) + prefs.favorites + defaults).filter { seen.insert($0).inserted }.compactMap { library.byName[$0]?.contentItem }
        case "All emoji": source = catalog.items
        default: source = catalog.items.filter { $0.category == category }
        }
        // Search from the default landing section covers the entire library.
        let searchable = category == "For you" && !search.stringValue.isEmpty ? catalog.items : source
        results = ContentSearch.search(search.stringValue, in: searchable, aliases: prefs.aliases)
        sectionLabel.stringValue = search.stringValue.isEmpty ? category : "Search results"
        countLabel.stringValue = "\(results.count) emoji"
        for (name, button) in sidebarButtons {
            button.layer?.backgroundColor = (name == category ? NSColor(white: 1, alpha: 0.12) : .clear).cgColor
            button.contentTintColor = name == category ? .white : .init(white: 0.7, alpha: 1)
        }
        toneButton.title = (library.byName["raised_hand"]?.rendered(tone: prefs.skinTone) ?? "✋") + "  ▾"
        grid.subviews.forEach { $0.removeFromSuperview() }; tiles = []
        let rows = (results.count + columns - 1) / columns
        grid.frame = NSRect(x: 0, y: 0, width: 522, height: max(CGFloat(rows * 59), scroll.contentSize.height))
        for (index, item) in results.enumerated() {
            let tile = EmojiTile(item: item, rendered: rendered(item), image: image(item),
                                 frame: NSRect(x: (index % columns) * 65, y: (index / columns) * 59, width: 62, height: 56))
            tile.favorite = item.kind == .unicodeEmoji && prefs.favorites.contains(item.name)
            tile.onChoose = { [weak self] in self?.onChoose?(item) }
            tile.onHover = { [weak self] in self?.select(index, scrollTo: false) }
            tile.onFavorite = { [weak self] in self?.toggleFavorite(item); self?.refresh() }
            tile.onAlias = { [weak self] in self?.editAlias(for: item) }
            grid.addSubview(tile); tiles.append(tile)
        }
        if results.isEmpty {
            label(category == "Recent" && search.stringValue.isEmpty ? "Your next favorite starts here." : "Nothing here just yet.",
                  NSRect(x: 50, y: 83, width: 450, height: 32), in: grid, size: 21, weight: .semibold)
            label(search.stringValue.isEmpty ? "Pick an emoji, or explore another collection." : "Try a feeling, an object, or a shorter name.",
                  NSRect(x: 50, y: 127, width: 450, height: 35), in: grid, size: 13, color: Palette.muted)
        }
        selected = 0; tiles.first?.selected = true; scroll.contentView.scroll(to: .zero)
        updateFooter()
    }
    private func select(_ index: Int, scrollTo: Bool) {
        guard results.indices.contains(index) else { return }
        if tiles.indices.contains(selected) { tiles[selected].selected = false }
        selected = index; tiles[index].selected = true
        if scrollTo { grid.scrollToVisible(tiles[index].frame) }
        updateFooter()
    }
    private func move(_ delta: Int) { select(min(max(0, selected + delta), results.count - 1), scrollTo: true) }
    private func chooseSelected() { if results.indices.contains(selected) { onChoose?(results[selected]) } }
    private func copySelected() {
        guard results.indices.contains(selected) else { return }
        let item = results[selected]
        if let emoji = emoji(item) { Inserter.copy(emoji.rendered(tone: prefs.skinTone)); prefs.record(emoji) }
        else { try? MacOSImageInsertionAdapter(resolver: assetResolver).copy(item) }
        statusLabel.stringValue = "Copied. Paste anywhere."
    }
    private func toggleSelectedFavorite() {
        guard results.indices.contains(selected) else { return }
        let item = results[selected]; toggleFavorite(item)
        if category == "Favorites" { refresh() }
        else { tiles[selected].favorite = item.kind == .unicodeEmoji && prefs.favorites.contains(item.name); updateFooter() }
    }
    private func updateFooter() {
        guard results.indices.contains(selected) else {
            nameLabel.stringValue = "Make yourself understood."; shortcodeLabel.stringValue = "⌃⌥Space opens Popmoji from any app"
            largeEmoji.stringValue = "✦"; favoriteButton.isHidden = true; return
        }
        let item = results[selected]; largeEmoji.stringValue = item.kind == .unicodeEmoji ? rendered(item) : "●"
        nameLabel.stringValue = item.description.capitalized; shortcodeLabel.stringValue = ":\(item.name):"
        favoriteButton.isHidden = item.kind != .unicodeEmoji; favoriteButton.title = prefs.favorites.contains(item.name) ? "♥" : "♡"
        statusLabel.stringValue = lastTrusted && targetName != nil ? "↵ insert  ·  ⌘C copy" : "↵ copy  ·  esc close"
        statusLabel.toolTip = targetName.map { "Insert into \($0)" } ?? "Copy to clipboard"
    }
    private func showTones() {
        let menu = NSMenu()
        for (index, title) in ["✋ Default", "✋🏻 Light", "✋🏼 Medium-light", "✋🏽 Medium", "✋🏾 Medium-dark", "✋🏿 Dark"].enumerated() {
            let item = NSMenuItem(title: title, action: #selector(setTone(_:)), keyEquivalent: "")
            item.target = self; item.tag = index; item.state = prefs.skinTone == index ? .on : .off; menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: toneButton.bounds.height), in: toneButton)
    }
    @objc private func setTone(_ sender: NSMenuItem) { prefs.skinTone = sender.tag; refresh() }
    private func rendered(_ item: ContentItem) -> String {
        emoji(item)?.rendered(tone: prefs.skinTone) ?? ""
    }
    private func emoji(_ item: ContentItem) -> Emoji? {
        guard item.kind == .unicodeEmoji else { return nil }
        return library.byName[item.name]
    }
    private func image(_ item: ContentItem) -> NSImage? {
        assetResolver.url(for: item).flatMap(NSImage.init(contentsOf:))
    }
    private func toggleFavorite(_ item: ContentItem) {
        if let emoji = emoji(item) { prefs.toggleFavorite(emoji) }
    }
    private func editAlias(for item: ContentItem) {
        guard let emoji = emoji(item) else { return }
        let alert = NSAlert(); alert.messageText = "A shortcut for \(emoji.emoji)"
        alert.informativeText = "Use letters, numbers, +, -, or _. Type :your-alias: in any app to insert this emoji."
        alert.addButton(withTitle: "Save Alias"); alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 28))
        field.placeholderString = "e.g. letsgo"; alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: panel) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let alias = field.stringValue.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard Preferences.validAlias(alias) else {
                self.statusLabel.stringValue = "Invalid alias. Try again."; return
            }
            if self.library.all.contains(where: { $0.aliases.contains(alias) && $0.name != item.name }) {
                self.statusLabel.stringValue = "Alias already belongs to an emoji."; return
            }
            self.prefs.aliases[alias] = item.name; self.refresh()
            self.statusLabel.stringValue = "Saved :\(alias):"
        }
    }
}

final class InlinePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
final class InlineController {
    let panel = InlinePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    var onChoose: ((Emoji) -> Void)?
    private(set) var results: [Emoji] = []
    private(set) var query = ""
    private var index = 0
    private var tone = 0
    init() {
        panel.level = .popUpMenu; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .aqua)
    }
    var selected: Emoji? { results.indices.contains(index) ? results[index] : nil }
    func show(query: String, results: [Emoji], tone: Int) {
        self.query = query; self.results = Array(results.prefix(6)); self.tone = tone; index = 0
        guard !self.results.isEmpty else { hide(); return }
        render()
        let caret = Accessibility.caretRect()
        let anchor = caret.map { NSPoint(x: $0.minX, y: $0.minY) } ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main!
        let bounds = screen.visibleFrame
        let height = panel.frame.height
        var y = anchor.y - height - 9
        if y < bounds.minY + 8 { y = (caret?.maxY ?? anchor.y) + 9 }
        panel.setFrameOrigin(NSPoint(x: min(max(anchor.x, bounds.minX + 8), bounds.maxX - panel.frame.width - 8),
                                     y: min(max(y, bounds.minY + 8), bounds.maxY - height - 8)))
        panel.orderFrontRegardless()
    }
    func navigate(_ delta: Int) {
        guard !results.isEmpty else { return }
        index = (index + delta + results.count) % results.count; render()
    }
    func hide() { panel.orderOut(nil); results = []; query = "" }
    private func render() {
        let height = CGFloat(48 + results.count * 42)
        panel.setContentSize(NSSize(width: 312, height: height))
        let root = ColorView(frame: NSRect(x: 0, y: 0, width: 312, height: height), color: Palette.paper, radius: 12)
        root.layer?.borderWidth = 1; root.layer?.borderColor = Palette.line.cgColor
        label("✳  POPMOJI", NSRect(x: 13, y: 10, width: 125, height: 18), in: root, size: 10, weight: .bold, color: Palette.purple)
        label("↑↓ choose   ↵ insert", NSRect(x: 166, y: 10, width: 139, height: 18), in: root, size: 10, color: Palette.muted)
        for (row, item) in results.enumerated() {
            let button = ActionButton("", frame: NSRect(x: 7, y: 35 + row * 42, width: 298, height: 40)) { [weak self] in self?.onChoose?(item) }
            button.wantsLayer = true; button.layer?.cornerRadius = 8
            button.layer?.backgroundColor = (row == index ? Palette.lavender : .clear).cgColor
            button.setAccessibilityLabel("\(item.description), :\(item.name):")
            root.addSubview(button)
            let emoji = label(item.rendered(tone: tone), NSRect(x: 12, y: 4, width: 37, height: 33), in: button, size: 25)
            emoji.isSelectable = false
            label(":\(item.name):", NSRect(x: 53, y: 11, width: 232, height: 21), in: button, size: 12, weight: row == index ? .semibold : .regular)
        }
        panel.contentView = root
    }
}
