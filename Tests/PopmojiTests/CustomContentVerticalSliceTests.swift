import AppKit
import XCTest
@testable import Popmoji

final class CustomContentVerticalSliceTests: XCTestCase {
    /// Checks the packaged manifest, reserved-item filtering, search, and actual image decoding.
    func testBundledPickleballBallIsSearchableAndHasAResolvableAsset() throws {
        let provider = BundledContentPackProvider(manifestName: "pickleball")
        let items = try provider.loadItems()

        XCTAssertEqual(items.map(\.id), ["pickleball:ball"])
        let result = try XCTUnwrap(ContentSearch.search("pickleball", in: items).first)
        XCTAssertEqual(result.kind, .customEmoji)
        let url = try XCTUnwrap(BundledContentAssetResolver().url(for: result))
        XCTAssertNotNil(NSImage(contentsOf: url))
    }

    /// Keeps the image delivery plan separate from the provider-neutral model.
    func testMacOSAdapterPlansImageInsertionWithoutChangingTheContentModel() throws {
        let item = try XCTUnwrap(
            BundledContentPackProvider(manifestName: "pickleball").loadItems().first
        )
        let adapter = MacOSImageInsertionAdapter(resolver: BundledContentAssetResolver())

        XCTAssertTrue(adapter.supports(item))
        XCTAssertEqual(
            try adapter.plan(for: item),
            InsertionPlan(mode: .richImage, textValue: nil, assetPath: "pickleball/ball.png")
        )
    }

    /// A missing optional manifest must leave the full Unicode catalog searchable.
    func testMissingPackPreservesUnicode() throws {
        let library = EmojiLibrary()
        let provider = BundledContentPackProvider(manifestName: "missing-test-pack")
        XCTAssertThrowsError(try provider.loadItems())

        let catalog = ContentCatalog(library: library, optionalProviders: [provider])
        XCTAssertEqual(catalog.items, library.all.map(\.contentItem))
        XCTAssertEqual(catalog.search("wave").first?.id, "unicode:wave")
    }

    /// An invalid optional manifest must not prevent Unicode or later valid packs from loading.
    func testInvalidPackPreservesUnicodeAndOtherPacks() throws {
        let bundle = try isolatedContentBundle()
        let manifest = try XCTUnwrap(bundle.resourceURL)
            .appendingPathComponent("ContentPacks/pickleball.json")
        try Data("{invalid json".utf8).write(to: manifest)
        let broken = BundledContentPackProvider(manifestName: "pickleball", bundle: bundle)
        XCTAssertThrowsError(try broken.loadItems())

        let library = EmojiLibrary()
        let catalog = ContentCatalog(library: library, optionalProviders: [
            broken, BundledContentPackProvider(manifestName: "pickleball")
        ])
        XCTAssertEqual(Array(catalog.items.prefix(library.all.count)), library.all.map(\.contentItem))
        XCTAssertEqual(catalog.search("pickleball").first?.id, "pickleball:ball")
    }

    /// Searches both providers, including a custom asset alias and a user-defined Unicode alias.
    func testMixedCatalogSearchPreservesUnicodeAliases() {
        let catalog = ContentCatalog(library: EmojiLibrary(), optionalProviders: [
            BundledContentPackProvider(manifestName: "pickleball")
        ])
        XCTAssertEqual(catalog.search("pb_ball").first?.id, "pickleball:ball")
        XCTAssertEqual(ContentSearch.search("hello", in: catalog.items, aliases: ["hello": "wave"])
            .first?.id, "unicode:wave")
    }

    /// Round-trips the bundled image through an isolated macOS pasteboard without altering the user's clipboard.
    func testImageCopyWritesReadableImage() throws {
        let item = try pickleballItem()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let adapter = MacOSImageInsertionAdapter(resolver: BundledContentAssetResolver())
        try adapter.copy(item) { image in
            pasteboard.clearContents()
            return pasteboard.writeObjects([image])
        }
        XCTAssertEqual(pasteboard.readObjects(forClasses: [NSImage.self], options: nil)?.count, 1)
    }

    /// A rejected clipboard write must throw rather than report a completed copy.
    func testRejectedClipboardWriteThrows() throws {
        let adapter = MacOSImageInsertionAdapter(resolver: BundledContentAssetResolver())
        var attemptedWrite = false
        XCTAssertThrowsError(try adapter.copy(pickleballItem()) { _ in
            attemptedWrite = true
            return false
        }) { error in
            guard case ContentModelError.clipboardWriteFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(attemptedWrite)
    }

    /// A corrupt image must fail before touching the clipboard and fail the insertion completion.
    func testCorruptImageDoesNotWriteOrReportInsertionSuccess() throws {
        let bundle = try isolatedContentBundle()
        let resolver = BundledContentAssetResolver(bundle: bundle)
        let item = try pickleballItem()
        let url = try XCTUnwrap(resolver.url(for: item))
        try Data("not an image".utf8).write(to: url)
        let adapter = MacOSImageInsertionAdapter(resolver: resolver)
        XCTAssertThrowsError(try adapter.copy(item) { _ in
            XCTFail("An invalid image must not reach the clipboard writer")
            return true
        }) { error in
            guard case ContentModelError.missingPayload = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        var completionResult: Bool?
        adapter.insert(item, into: NSRunningApplication.current) { completionResult = $0 }
        XCTAssertEqual(completionResult, false)
    }

    /// A removed asset must fail before touching the clipboard.
    func testMissingImageDoesNotWrite() throws {
        let bundle = try isolatedContentBundle()
        let resolver = BundledContentAssetResolver(bundle: bundle)
        let item = try pickleballItem()
        try FileManager.default.removeItem(at: XCTUnwrap(resolver.url(for: item)))
        let adapter = MacOSImageInsertionAdapter(resolver: resolver)
        XCTAssertThrowsError(try adapter.copy(item) { _ in
            XCTFail("A missing image must not reach the clipboard writer")
            return true
        })
    }

    /// Returns the real bundled asset so clipboard tests exercise the shipping content.
    private func pickleballItem() throws -> ContentItem {
        try XCTUnwrap(BundledContentPackProvider(manifestName: "pickleball").loadItems().first)
    }

    /// Copies the resource bundle to a temporary location for destructive failure fixtures.
    private func isolatedContentBundle() throws -> Bundle {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ContentTests.bundle")
        try FileManager.default.copyItem(at: BundledContentAssetResolver().bundle.bundleURL, to: url)
        return try XCTUnwrap(Bundle(url: url))
    }
}
