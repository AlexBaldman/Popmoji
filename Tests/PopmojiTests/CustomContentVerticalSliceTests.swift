import XCTest
@testable import Popmoji

final class CustomContentVerticalSliceTests: XCTestCase {
    func testBundledPickleballBallIsSearchableAndHasAResolvableAsset() throws {
        let provider = BundledContentPackProvider(manifestName: "pickleball")
        let items = try provider.loadItems()

        XCTAssertEqual(items.map(\.id), ["pickleball:ball"])
        let result = try XCTUnwrap(ContentSearch.search("pickleball", in: items).first)
        XCTAssertEqual(result.kind, .customEmoji)
        XCTAssertNotNil(BundledContentAssetResolver().url(for: result))
    }

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
}
