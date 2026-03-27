import ProjectDescription

let appName = "OpenSonos"

let project = Project(
    name: "open-sonos",
    targets: [
        .target(
            name: appName,
            destinations: .macOS,
            product: .app,
            bundleId: "dev.kinan.opensonos",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": .string(appName),
                "CFBundleURLTypes": .array([
                    .dictionary([
                        "CFBundleURLName": .string("dev.kinan.opensonos.oauth"),
                        "CFBundleURLSchemes": .array([
                            .string("opensonos"),
                        ]),
                    ]),
                ]),
                "LSUIElement": .boolean(true),
                "LSMinimumSystemVersion": .string("14.0"),
                "NSAppTransportSecurity": .dictionary([
                    "NSAllowsLocalNetworking": .boolean(true),
                ]),
                "NSLocalNetworkUsageDescription": .string("OpenSonos scans your local network to discover and control Sonos speakers nearby."),
            ]),
            sources: ["open-sonos/Sources/**"],
            resources: ["open-sonos/Resources/**"],
            dependencies: []
        ),
        .target(
            name: "OpenSonosTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "dev.kinan.opensonosTests",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .default,
            sources: ["open-sonos/Tests/**"],
            dependencies: [.target(name: appName)]
        ),
    ]
)
