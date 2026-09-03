// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HardwareSentryCore",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "MonitorRegistry", targets: ["MonitorRegistry"]),
        .library(name: "SentryContract", targets: ["SentryContract"])
    ],
    dependencies: [
        .package(path: "../../SignalCore")
    ],
    targets: [
        // Prints the catalogue as JSON, for `Tools/parity-audit.sh`. An executable rather
        // than a test so the audit can be run on its own, without a build of the app.
        .executableTarget(
            name: "sentry-inventory",
            dependencies: ["MonitorRegistry", "SentryContract"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // What every monitor is allowed to know about. Deliberately small: a monitor
        // depends on this and on nothing else of the application.
        .target(
            name: "SentryContract",
            dependencies: [.product(name: "SignalCore", package: "SignalCore")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // One module per monitor. Being separate modules is what keeps them apart: what
        // is internal to one is invisible to the others, enforced by the compiler rather
        // than by anyone remembering to be careful.
        .target(
            name: "USBMonitor",
            dependencies: ["SentryContract"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "ThermalMonitor",
            dependencies: ["SentryContract"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "GamepadMonitor",
            dependencies: ["SentryContract"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "ThunderboltMonitor",
            dependencies: ["SentryContract"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "ScannerMonitor",
            dependencies: ["SentryContract"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "CameraMonitor",
            dependencies: ["SentryContract"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "DisplayMonitor",
            dependencies: ["SentryContract"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // Genuine C bridge (not a constant-casting fix like the others) — CUPS is a real C
        // library with no Swift overlay, so PrinterMonitor needs a system-library target
        // that imports its headers and links libcups. See CCUPS/shim.h.
        .systemLibrary(name: "CCUPS"),
        .target(
            name: "PrinterMonitor",
            dependencies: ["SentryContract", "CCUPS"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "BluetoothMonitor",
            dependencies: ["SentryContract"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "AudioMonitor",
            dependencies: ["SentryContract"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // A C shim, for the same reason CCUPS is one: the header ships in the SDK but is
        // not in IOKit's module map, so Swift cannot see it — and the interface behind it
        // is an IOCFPlugIn function-pointer table, which is the shape Swift handles worst.
        .target(name: "CNVMeSMART"),
        .target(
            name: "VolumeMonitor",
            dependencies: ["SentryContract", "CNVMeSMART"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "PowerMonitor",
            dependencies: ["SentryContract"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "NetworkMonitor",
            dependencies: ["SentryContract"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // The only place that knows the whole list.
        .target(
            name: "MonitorRegistry",
            dependencies: ["SentryContract", "USBMonitor", "ThermalMonitor", "GamepadMonitor", "ThunderboltMonitor", "ScannerMonitor", "CameraMonitor", "DisplayMonitor", "PrinterMonitor", "BluetoothMonitor", "AudioMonitor", "VolumeMonitor", "PowerMonitor", "NetworkMonitor"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        .testTarget(
            name: "SentryContractTests",
            dependencies: ["SentryContract"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "USBMonitorTests",
            dependencies: ["USBMonitor"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ThermalMonitorTests",
            dependencies: ["ThermalMonitor"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "GamepadMonitorTests",
            dependencies: ["GamepadMonitor"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ThunderboltMonitorTests",
            dependencies: ["ThunderboltMonitor"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ScannerMonitorTests",
            dependencies: ["ScannerMonitor"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CameraMonitorTests",
            dependencies: ["CameraMonitor"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DisplayMonitorTests",
            dependencies: ["DisplayMonitor"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            // CCUPS as well, so the capability test can name the real bits rather than
            // hardcoding numbers that would not follow the header if it ever changed.
            name: "PrinterMonitorTests",
            dependencies: ["PrinterMonitor", "CCUPS"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BluetoothMonitorTests",
            dependencies: ["BluetoothMonitor"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AudioMonitorTests",
            dependencies: ["AudioMonitor"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "VolumeMonitorTests",
            dependencies: ["VolumeMonitor"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PowerMonitorTests",
            dependencies: ["PowerMonitor"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "NetworkMonitorTests",
            dependencies: ["NetworkMonitor"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
