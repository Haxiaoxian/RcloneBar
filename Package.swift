// swift-tools-version:5.9
import PackageDescription

// RcloneBar
// - RcloneBarCore: 纯 Foundation 共享逻辑（macOS 与 Linux 均可编译，便于测试）
// - rclonebar-agent: 后台调度服务（LaunchAgent），独立于菜单栏界面运行
// - RcloneBar: SwiftUI 菜单栏 App（仅 macOS）

var targets: [Target] = [
    .target(
        name: "RcloneBarCore",
        path: "Sources/RcloneBarCore"
    ),
    .executableTarget(
        name: "rclonebar-agent",
        dependencies: ["RcloneBarCore"],
        path: "Sources/RcloneBarAgent"
    ),
    .testTarget(
        name: "RcloneBarCoreTests",
        dependencies: ["RcloneBarCore"],
        path: "Tests/RcloneBarCoreTests"
    ),
]

var products: [Product] = [
    .executable(name: "rclonebar-agent", targets: ["rclonebar-agent"]),
]

#if os(macOS)
targets.append(
    .executableTarget(
        name: "RcloneBar",
        dependencies: ["RcloneBarCore"],
        path: "Sources/RcloneBar"
    )
)
products.append(.executable(name: "RcloneBar", targets: ["RcloneBar"]))
#endif

let package = Package(
    name: "RcloneBar",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
