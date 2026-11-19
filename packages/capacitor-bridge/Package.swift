// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DeskfleetCapacitorBridge",
    platforms: [.iOS(.v16)],
    products: [
        .library(
            name: "DeskfleetCapacitorBridge",
            targets: ["DeskFleetBridge"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/ionic-team/capacitor-swift-pm.git", from: "8.6.2"),
        .package(url: "https://github.com/firebase/firebase-ios-sdk.git", exact: "13.2.0")
    ],
    targets: [
        .binaryTarget(
            name: "DeskfleetDesktopViewerFFI",
            path: "ios/Frameworks/DeskfleetDesktopViewerFFI.xcframework"
        ),
        .binaryTarget(
            name: "IshPlusRPPairing",
            path: "ios/Frameworks/IshPlusRPPairing.xcframework"
        ),
        .binaryTarget(
            name: "Librvvm",
            path: "ios/Frameworks/Librvvm.xcframework"
        ),
        .target(
            name: "RvvmRuntime",
            dependencies: [
                "Librvvm"
            ],
            path: "ios/Sources/RvvmRuntime",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedLibrary("z")
            ]
        ),
        .target(
            name: "DeskFleetBridge",
            dependencies: [
                .product(name: "Capacitor", package: "capacitor-swift-pm"),
                .product(name: "Cordova", package: "capacitor-swift-pm"),
                .product(name: "FirebaseAnalytics", package: "firebase-ios-sdk"),
                "DeskfleetDesktopViewerFFI",
                "IshPlusRPPairing",
                "Librvvm",
                "RvvmRuntime"
            ],
            path: "ios/Sources/DeskFleetBridge",
            resources: [.process("PrivacyInfo.xcprivacy")],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AuthenticationServices"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Foundation"),
                .linkedFramework("IOSurface"),
                .linkedFramework("Metal"),
                .linkedFramework("Network"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("ReplayKit"),
                .linkedFramework("Security"),
                .linkedFramework("Speech"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("UIKit"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("VideoToolbox"),
                .linkedLibrary("c++"),
                .linkedLibrary("resolv")
            ]
        )
    ]
)
