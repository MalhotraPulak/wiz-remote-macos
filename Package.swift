// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "WizRemote",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "WizRemote", targets: ["WizRemote"])
    ],
    targets: [
        .executableTarget(
            name: "WizRemote",
            path: "WizRemote",
            exclude: ["Assets.xcassets"],
            resources: [
                .process("on.wav"),
                .process("off.wav")
            ]
        )
    ]
)
