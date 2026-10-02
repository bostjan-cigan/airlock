// swift-tools-version: 6.0
import PackageDescription

// A notes client for iOS and macOS apps. AIrlock test project: an Apple-platform
// package, which a Linux container can edit but not build or test.
let package = Package(
    name: "NotesKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "NotesKit", targets: ["NotesKit"])],
    targets: [
        .target(name: "NotesKit"),
        .testTarget(name: "NotesKitTests", dependencies: ["NotesKit"]),
    ]
)
