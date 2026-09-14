import Foundation

struct Emoji: Codable, Equatable {
    let emoji: String
    let description: String
    let category: String
    let aliases: [String]
    let tags: [String]
    let skinTones: Bool?
    var name: String { aliases.first ?? description }
    enum CodingKeys: String, CodingKey {
        case emoji, description, category, aliases, tags
        case skinTones = "skin_tones"
    }

    func rendered(tone: Int) -> String {
        guard skinTones == true, (1...5).contains(tone),
              let modifier = UnicodeScalar(0x1F3FA + tone) else { return emoji }
        // Mixed-person ZWJ sequences need individual modifiers; preserve their base form.
        let scalars = Array(emoji.unicodeScalars)
        let people = scalars.filter { (0x1F466...0x1F469).contains($0.value) || (0x1F9D1...0x1F9DD).contains($0.value) }
        guard people.count < 2 else { return emoji }
        var result = String(scalars[0]) + String(modifier)
        var rest = scalars.dropFirst()
        if rest.first?.value == 0xFE0F { rest = rest.dropFirst() }
        result += String(String.UnicodeScalarView(rest))
        return result
    }
}

final class EmojiLibrary {
    let all: [Emoji]
    let byName: [String: Emoji]
    let categories: [String]

    init() {
        guard let url = Bundle.module.url(forResource: "emoji", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Emoji].self, from: data) else {
            fatalError("Popmoji's bundled emoji library is missing or invalid. Rebuild the app with scripts/build.sh.")
        }
        all = decoded
        byName = Dictionary(decoded.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        categories = decoded.reduce(into: []) { if !$0.contains($1.category) { $0.append($1.category) } }
    }

    func search(_ text: String, aliases: [String: String] = [:], in source: [Emoji]? = nil) -> [Emoji] {
        let query = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ": \n\t"))
        let candidates = source ?? all
        guard !query.isEmpty else { return candidates }
        let words = query.replacingOccurrences(of: "_", with: " ").split(separator: " ").map(String.init)
        return candidates.compactMap { item -> (Emoji, Int)? in
            let custom = aliases.filter { $0.value == item.name }.map(\.key)
            let names = item.aliases + custom
            let normalizedNames = names.map { $0.replacingOccurrences(of: "_", with: " ") }
            let haystack = (normalizedNames + [item.description.lowercased()] + item.tags).joined(separator: " ")
            let score: Int
            if names.contains(query) || item.emoji == query { score = 1000 }
            else if names.contains(where: { $0.hasPrefix(query) }) { score = 800 }
            else if item.tags.contains(query) { score = 700 }
            else if words.allSatisfy({ haystack.contains($0) }) { score = 500 }
            else if query.count >= 3 && names.contains(where: { Self.isSubsequence(query, of: $0) }) { score = 100 }
            else { return nil }
            return (item, score)
        }.sorted { $0.1 == $1.1 ? $0.0.name < $1.0.name : $0.1 > $1.1 }.map(\.0)
    }

    static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var cursor = needle.startIndex
        for character in haystack {
            if cursor == needle.endIndex { return true }
            if character == needle[cursor] { cursor = needle.index(after: cursor) }
        }
        return cursor == needle.endIndex
    }
}

final class Preferences {
    private let defaults: UserDefaults
    var favorites: [String] { didSet { defaults.set(favorites, forKey: "favorites") } }
    var recents: [String] { didSet { defaults.set(recents, forKey: "recents") } }
    var aliases: [String: String] { didSet { defaults.set(aliases, forKey: "aliases") } }
    var skinTone: Int { didSet { defaults.set(skinTone, forKey: "skinTone") } }
    var autocomplete: Bool { didSet { defaults.set(autocomplete, forKey: "autocomplete") } }
    var excludedApps: [String] { didSet { defaults.set(excludedApps, forKey: "excludedApps") } }
    var insertions: Int { didSet { defaults.set(insertions, forKey: "insertions") } }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        favorites = defaults.stringArray(forKey: "favorites") ?? ["heart", "joy", "fire", "+1", "sparkles", "rocket"]
        recents = defaults.stringArray(forKey: "recents") ?? []
        aliases = defaults.dictionary(forKey: "aliases") as? [String: String] ?? [:]
        skinTone = min(5, max(0, defaults.integer(forKey: "skinTone")))
        autocomplete = defaults.object(forKey: "autocomplete") as? Bool ?? true
        excludedApps = defaults.stringArray(forKey: "excludedApps") ?? []
        insertions = defaults.integer(forKey: "insertions")
    }
    func record(_ emoji: Emoji) {
        recents = [emoji.name] + recents.filter { $0 != emoji.name }.prefix(39)
        insertions += 1
    }
    func toggleFavorite(_ emoji: Emoji) {
        if favorites.contains(emoji.name) { favorites.removeAll { $0 == emoji.name } }
        else { favorites.append(emoji.name) }
    }
    static func validAlias(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 40 && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_+-".contains($0)) }
    }
}

/// Stores only the active shortcode, never surrounding typed text.
struct ShortcodeTracker {
    private(set) var query: String?
    private var canStart = true
    mutating func reset() { query = nil; canStart = true }
    mutating func cancel() { query = nil; canStart = false }
    mutating func backspace() {
        guard let current = query else { canStart = false; return }
        if current.isEmpty { cancel() } else { query = String(current.dropLast()) }
    }
    mutating func type(_ character: String) {
        if character == ":" {
            if canStart && query == nil { query = ""; canStart = false }
            else { cancel() }
            return
        }
        if let current = query {
            if character.count == 1 && Preferences.validAlias(character) && current.count < 40 {
                query = current + character
                return
            }
            query = nil
        }
        canStart = character.last.map { $0.isWhitespace || "([{\"'".contains($0) } ?? false
    }
}
