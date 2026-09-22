// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Popmoji",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Popmoji", targets: ["Popmoji"])],
    targets: [
        .executableTarget(name: "Popmoji", resources: [
            .process("Resources/emoji.json"),
            .process("Resources/GEMOJI-LICENSE.txt"),
            .copy("Resources/ContentPacks")
        ]),
        .testTarget(name: "PopmojiTests", dependencies: ["Popmoji"])
    ]
)
