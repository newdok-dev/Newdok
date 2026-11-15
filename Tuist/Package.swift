// swift-tools-version:6.1
import PackageDescription

#if TUIST
import ProjectDescription

let packageSettings = PackageSettings(
    productTypes: [
        "ComposableArchitecture": .framework,
        "Moya": .framework,
        "Swinject": .framework,
        "Kingfisher": .framework,
        "PopupView": .framework,
        "KakaoSDKCommon": .framework,
        "KakaoSDKAuth": .framework,
        "KakaoSDKUser": .framework,
    ],
    // 패키지의 deployment target은 타깃 수준에 생성되므로 baseSettings로 덮어쓸 수 없다.
    // 앱에서 사용하는 외부 소스 타깃도 ProjectConfig와 동일한 iOS 18 기준으로 빌드한다.
    targetSettings: Dictionary(uniqueKeysWithValues: [
        "Alamofire",
        "Firebase",
        "FirebaseAnalyticsTarget",
        "FirebaseAnalyticsWrapper",
        "FirebaseCore",
        "FirebaseCoreExtension",
        "FirebaseCoreInternal",
        "FirebaseCrashlytics",
        "FirebaseCrashlyticsSwift",
        "FirebaseInstallations",
        "FirebaseRemoteConfigInterop",
        "FirebaseSessions",
        "FirebaseSessionsObjC",
        "GoogleAdsOnDeviceConversionTarget",
        "GoogleAppMeasurementTarget",
        "GoogleDataTransport",
        "GoogleUtilities-AppDelegateSwizzler",
        "GoogleUtilities-Environment",
        "GoogleUtilities-Logger",
        "GoogleUtilities-MethodSwizzler",
        "GoogleUtilities-NSData",
        "GoogleUtilities-Network",
        "GoogleUtilities-Reachability",
        "GoogleUtilities-UserDefaults",
        "third-party-IsAppEncrypted",
        "KakaoSDKAuth",
        "KakaoSDKCommon",
        "KakaoSDKUser",
        "Kingfisher",
        "Moya",
        "PopupView",
        "FBLPromises",
        "Promises",
        "Swinject",
        "nanopb",
        "SwiftUIIntrospect",
    ].map { ($0, Settings.settings(base: ["IPHONEOS_DEPLOYMENT_TARGET": "18.0"])) })
    // TCA's graph includes Perception backports obsoleted in iOS 17.
    // Keep this external graph at iOS 16; all first-party targets remain iOS 18.
    .merging(Dictionary(uniqueKeysWithValues: [
        "ComposableArchitecture",
        "CasePaths",
        "CasePathsCore",
        "Clocks",
        "CombineSchedulers",
        "ConcurrencyExtras",
        "CustomDump",
        "Dependencies",
        "DependenciesMacros",
        "IdentifiedCollections",
        "InternalCollectionsUtilities",
        "OrderedCollections",
        "IssueReporting",
        "IssueReportingTestSupport",
        "XCTestDynamicOverlay",
        "Perception",
        "PerceptionCore",
        "Sharing",
        "Sharing1",
        "Sharing2",
        "SwiftNavigation",
        "SwiftUINavigation",
        "UIKitNavigation",
        "UIKitNavigationShim",
    ].map { ($0, Settings.settings(base: ["IPHONEOS_DEPLOYMENT_TARGET": "16.0"])) }), uniquingKeysWith: { current, _ in current })
    .merging(Dictionary(uniqueKeysWithValues: [
        // Macro executables and their host libraries must target a supported macOS SDK.
        "ComposableArchitectureMacros", "CasePathsMacros", "CasePathsMacrosSupport", "DependenciesMacrosPlugin", "PerceptionMacros", "SwiftNavigationMacros",
        "SwiftBasicFormat", "SwiftCompilerPlugin", "SwiftCompilerPluginMessageHandling", "SwiftDiagnostics", "SwiftIfConfig",
        "SwiftOperators", "SwiftParser", "SwiftParserDiagnostics", "SwiftSyntax", "SwiftSyntaxBuilder",
        "SwiftSyntaxMacroExpansion", "SwiftSyntaxMacros", "_SwiftSyntaxCShims",
        "SwiftSyntax509", "SwiftSyntax510", "SwiftSyntax600", "SwiftSyntax601", "SwiftSyntax602", "SwiftSyntax603", "SwiftSyntax604",
    ].map { ($0, Settings.settings(base: ["MACOSX_DEPLOYMENT_TARGET": "13.0"])) }), uniquingKeysWith: { current, _ in current })
)
#endif

let package = Package(
    name: "MyProjectDependencies",
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-composable-architecture.git", exact: "1.26.2"),
        // Tuist 4.143.0 cannot decode the newer strictMemorySafety package setting.
        .package(url: "https://github.com/apple/swift-collections", exact: "1.7.1"),
        // Tuist 4.143.0 expands default traits for compiler flags, but not dependency edges.
        // Declare the packages' default traits explicitly so Xcode builds every imported module first.
        .package(url: "https://github.com/pointfreeco/swift-dependencies", exact: "1.17.2", traits: [
            .defaults, .trait(name: "Clocks"), .trait(name: "CombineSchedulers"),
        ]),
        .package(url: "https://github.com/pointfreeco/swift-navigation", exact: "2.11.2", traits: [
            .defaults, .trait(name: "CasePaths"), .trait(name: "CustomDump"),
            .trait(name: "IssueReporting"), .trait(name: "Perception"),
        ]),
        .package(url: "https://github.com/pointfreeco/swift-sharing", exact: "2.10.1", traits: [
            .defaults, .trait(name: "CasePaths"), .trait(name: "CustomDump"), .trait(name: "IdentifiedCollections"),
        ]),
        .package(url: "https://github.com/Moya/Moya.git", from: "15.0.0"),
        .package(url: "https://github.com/Swinject/Swinject.git", from: "2.8.0"),
        .package(url: "https://github.com/onevcat/Kingfisher.git", from: "8.0.0"),
        .package(url: "https://github.com/exyte/PopupView.git", from: "4.1.13"),
        .package(url: "https://github.com/firebase/firebase-ios-sdk.git", from: "12.19.1"),
        .package(url: "https://github.com/kakao/kakao-ios-sdk.git", from: "2.22.0"),
    ]
)
