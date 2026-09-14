import AppKit

if CommandLine.arguments.contains("--diagnostics") {
    let library = EmojiLibrary()
    print("Popmoji 0.1.0")
    print("Emoji: \(library.all.count)")
    print("Categories: \(library.categories.count)")
    print("Accessibility: \(Accessibility.trusted ? "enabled" : "not enabled")")
    print("Bundle: \(Bundle.main.bundlePath)")
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
