// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Bmux",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "bmux", targets: ["BmuxApp"]),
        // WINCH-aware PTY recorder; installed next to panes as `bmux-launch`.
        .executable(name: "bmux-launch", targets: ["BmuxLaunch"]),
    ],
    dependencies: [
        // libghostty Swift integration (community SPM wrapper around upstream Ghostty).
        // Pinned to an exact version for reproducibility. See README "Dependency pins".
        // Upstream Ghostty commit for this wrapper: see Ghostty.ref in the dependency
        // (0c2a290d3a3e2a599be3a43435d778a5896667ee on main at time of writing).
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", exact: "1.6.20260909"),
    ],
    targets: [
        .executableTarget(
            name: "BmuxApp",
            dependencies: [
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
                .product(name: "GhosttyTheme", package: "libghostty-spm"),
            ],
            path: "Sources/BmuxApp"
        ),
        .executableTarget(
            name: "BmuxLaunch",
            path: "Sources/BmuxLaunch"
        ),
    ]
)
