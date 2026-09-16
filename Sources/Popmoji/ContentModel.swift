import Foundation

enum ContentKind: String, Codable, CaseIterable, Hashable {
    case unicodeEmoji
    case customEmoji
    case sticker
    case gif
    case symbol
    case kaomoji
}

struct ContentItem: Codable, Equatable, Hashable, Identifiable {
    let id: String
    let kind: ContentKind
    let name: String
    let description: String
    let category: String
    let aliases: [String]
    let tags: [String]
    let textValue: String?
    let assetPath: String?
    let altText: String
    let source: String

    var searchableText: String {
        ([name, description, category] + aliases + tags)
            .joined(separator: " ")
            .lowercased()
    }
}

struct ContentPackManifest: Codable, Equatable {
    let id: String
    let name: String
    let version: Int
    let items: [ContentItem]
}

protocol ContentProvider {
    var identifier: String { get }
    var displayName: String { get }
    func loadItems() throws -> [ContentItem]
}

struct UnicodeEmojiProvider: ContentProvider {
    let library: EmojiLibrary

    var identifier: String { "unicode" }
    var displayName: String { "Unicode Emoji" }

    func loadItems() throws -> [ContentItem] {
        library.all.map(\.contentItem)
    }
}

extension Emoji {
    var contentItem: ContentItem {
        ContentItem(
            id: "unicode:\(name)",
            kind: .unicodeEmoji,
            name: name,
            description: description,
            category: category,
            aliases: aliases,
            tags: tags,
            textValue: emoji,
            assetPath: nil,
            altText: description,
            source: "unicode"
        )
    }
}

struct ContentSearch {
    static func search(_ text: String, in items: [ContentItem]) -> [ContentItem] {
        let query = text
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ": \n\t"))
            .replacingOccurrences(of: "_", with: " ")

        guard !query.isEmpty else { return items }
        let words = query.split(separator: " ").map(String.init)

        return items.compactMap { item -> (ContentItem, Int)? in
            let names = ([item.name] + item.aliases)
                .map { $0.lowercased().replacingOccurrences(of: "_", with: " ") }
            let tags = item.tags.map(\.lowercased)
            let haystack = item.searchableText.replacingOccurrences(of: "_", with: " ")

            let score: Int
            if names.contains(query) || item.textValue == query { score = 1000 }
            else if names.contains(where: { $0.hasPrefix(query) }) { score = 800 }
            else if tags.contains(query) { score = 700 }
            else if words.allSatisfy({ haystack.contains($0) }) { score = 500 }
            else if query.count >= 3 && names.contains(where: { EmojiLibrary.isSubsequence(query, of: $0) }) { score = 100 }
            else { return nil }

            return (item, score)
        }
        .sorted { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0.name < rhs.0.name : lhs.1 > rhs.1
        }
        .map(\.0)
    }
}

enum InsertionMode: String, Codable, CaseIterable, Hashable {
    case plainText
    case richImage
    case adaptiveImageGlyph
    case clipboard
    case share
}

struct InsertionPlan: Equatable {
    let mode: InsertionMode
    let textValue: String?
    let assetPath: String?
}

protocol ContentInsertionAdapter {
    var identifier: String { get }
    var supportedModes: Set<InsertionMode> { get }
    func supports(_ item: ContentItem) -> Bool
    func plan(for item: ContentItem) throws -> InsertionPlan
}

enum ContentModelError: Error {
    case unsupportedContent(ContentItem.ID)
    case missingPayload(ContentItem.ID)
}
