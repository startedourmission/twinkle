// swift-tools-version: 6.0
import PackageDescription

// 앱 확장(위젯)에서도 쓸 수 있는 API만 쓰도록
let extensionSafe: [SwiftSetting] = [.unsafeFlags(["-application-extension"])]

let package = Package(
    name: "Twinkle",
    platforms: [.macOS(.v14)],
    targets: [
        // 앱과 위젯이 같이 쓰는 것 (위젯용 할 일 목록 형식)
        .target(name: "TwinkleShared", swiftSettings: extensionSafe),
        .executableTarget(name: "Twinkle", dependencies: ["TwinkleShared"]),
        // 바탕화면·알림 센터 위젯. make-app.sh가 Twinkle.app/Contents/PlugIns/TwinkleWidgets.appex로 묶음
        .executableTarget(
            name: "TwinkleWidgets",
            dependencies: ["TwinkleShared"],
            swiftSettings: extensionSafe,
            // 확장은 시스템이 띄워 주는 _NSExtensionMain에서 시작해야 위젯으로 인식됨 (Xcode 위젯 대상과 같게)
            linkerSettings: [.unsafeFlags(["-Xlinker", "-application_extension", "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]
        ),
    ]
)
