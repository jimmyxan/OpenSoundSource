// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OpenSoundSource",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(
            name: "OpenSoundSource",
            // embed Info.plist so TCC shows the audio-capture prompt
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Info.plist"])]
        )
    ]
)
