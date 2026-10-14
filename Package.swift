// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "DayTraceCore", platforms: [.macOS(.v13)], products: [.library(name: "DayTraceCore", targets: ["DayTraceCore"])], targets: [.target(name: "DayTraceCore", path: "Shared"), .testTarget(name: "DayTraceCoreTests", dependencies: ["DayTraceCore"], path: "Tests")])
