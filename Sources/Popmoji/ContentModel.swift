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

    /// Combines searchable metadata in lowercase for shared catalog matching.
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
    /// Loads available content or throws when its source cannot be read or decoded.
    func loadItems() throws -> [ContentItem]
}

struct BundledContentPackProvider: ContentProvider {
    let manifestName: String
    let bundle: Bundle

    /// Selects a bundled manifest; the bundle can be replaced for validation fixtures.
    init(manifestName: String, bundle: Bundle = .module) {
        self.manifestName = manifestName
        self.bundle = bundle
    }

    var identifier: String { manifestName }
    var displayName: String { manifestName }

    /// Loads available content or throws when its source cannot be read or decoded.
    func loadItems() throws -> [ContentItem] {
        guard let url = bundle.url(
            forResource: manifestName,
            withExtension: "json",
            subdirectory: "ContentPacks"
        ) else {
            throw ContentModelError.missingManifest(manifestName)
        }
        let manifest = try JSONDecoder().decode(
            ContentPackManifest.self,
            from: Data(contentsOf: url)
        )
        // A manifest may reserve future entries. Only publish items whose payload is
        // actually bundled so search never advertises an unusable result.
        return manifest.items.filter { item in
            if item.textValue != nil { return true }
            guard let assetPath = item.assetPath,
                  let resourceURL = bundle.resourceURL else { return false }
            let url = resourceURL
                .appendingPathComponent("ContentPacks", isDirectory: true)
                .appendingPathComponent(assetPath)
            return FileManager.default.fileExists(atPath: url.path)
        }
    }
}

struct ContentCatalog {
    let items: [ContentItem]

    /// Loads every provider, propagating an error if any required provider fails.
    init(providers: [any ContentProvider]) throws {
        items = try providers.flatMap { try $0.loadItems() }
    }

    /// Keeps Unicode available while omitting and logging any optional pack that fails to load.
    init(library: EmojiLibrary, optionalProviders: [any ContentProvider]) {
        var loaded = UnicodeEmojiProvider(library: library).loadItems()
        for provider in optionalProviders {
            do { loaded += try provider.loadItems() }
            catch { NSLog("Skipping content pack %@: %@", provider.identifier, error.localizedDescription) }
        }
        items = loaded
    }

    /// Searches the loaded catalog using the shared content ranking rules.
    func search(_ text: String) -> [ContentItem] {
        ContentSearch.search(text, in: items)
    }
}

struct BundledContentAssetResolver {
    let bundle: Bundle

    /// Resolves assets from the supplied resource bundle, defaulting to the app content bundle.
    init(bundle: Bundle = .module) {
        self.bundle = bundle
    }

    /// Returns an existing asset URL beneath ContentPacks, or nil when the payload is absent.
    func url(for item: ContentItem) -> URL? {
        guard let assetPath = item.assetPath,
              let url = bundle.resourceURL?
            .appendingPathComponent("ContentPacks", isDirectory: true)
            .appendingPathComponent(assetPath),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}

struct UnicodeEmojiProvider: ContentProvider {
    let library: EmojiLibrary

    var identifier: String { "unicode" }
    var displayName: String { "Unicode Emoji" }

    /// Maps the already-loaded Unicode library without performing fallible resource reads.
    func loadItems() -> [ContentItem] {
        library.all.map(\.contentItem)
    }
}

extension Emoji {
    /// Preserves the Unicode payload and metadata under a provider-qualified identity.
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
    /// Returns provider-neutral content ranked by canonical names, user aliases, tags, and fuzzy matches.
    static func search(_ text: String, in items: [ContentItem], aliases: [String: String] = [:]) -> [ContentItem] {
        let query = text
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ": \n\t"))
            .replacingOccurrences(of: "_", with: " ")

        guard !query.isEmpty else { return items }
        let words = query.split(separator: " ").map(String.init)

        return items.compactMap { item -> (ContentItem, Int)? in
            let customAliases = aliases.filter { $0.value == item.name }.map(\.key)
            let names = ([item.name] + item.aliases + customAliases)
                .map { $0.lowercased().replacingOccurrences(of: "_", with: " ") }
            let tags = item.tags.map { $0.lowercased() }
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
    /// Reports whether the adapter can plan delivery for this item.
    func supports(_ item: ContentItem) -> Bool
    /// Returns a platform delivery plan or throws when the item is unsupported.
    func plan(for item: ContentItem) throws -> InsertionPlan
}

enum ContentModelError: LocalizedError {
    case unsupportedContent(ContentItem.ID)
    case missingPayload(ContentItem.ID)
    case missingManifest(String)
    case clipboardWriteFailed

    /// Supplies user-facing feedback for missing content and rejected clipboard writes.
    var errorDescription: String? {
        switch self {
        case .unsupportedContent: return "This item's image is unavailable."
        case .missingPayload: return "This item's image could not be loaded."
        case .missingManifest(let name): return "The content pack \(name) is missing."
        case .clipboardWriteFailed: return "The clipboard did not accept the image. Try copying again."
        }
    }
}
