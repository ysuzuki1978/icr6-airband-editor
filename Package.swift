// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ICR6Editor",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ICR6Editor", targets: ["ICR6Editor"])],
    targets: [
        .systemLibrary(
            name: "CLibUSB",
            pkgConfig: "libusb-1.0",
            providers: [.brew(["libusb"])]
        ),
        .target(name: "R6Core", dependencies: ["CLibUSB"], resources: [.process("Resources")]),
        .executableTarget(name: "ICR6Editor", dependencies: ["R6Core"]),
        .testTarget(name: "R6CoreTests", dependencies: ["R6Core"])
    ]
)
