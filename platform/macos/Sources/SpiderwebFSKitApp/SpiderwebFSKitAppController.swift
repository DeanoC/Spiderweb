import Foundation
import FSKit
import SwiftUI

private enum SpiderwebStatusProbe {
    case yes
    case no
    case unknown(String)

    var label: String {
        switch self {
        case .yes:
            return "Yes"
        case .no:
            return "No"
        case .unknown(let detail):
            return "Unknown (\(detail))"
        }
    }
}

@MainActor
final class SpiderwebFSKitAppController: ObservableObject {
    @Published private(set) var recentRequests: [SpiderwebRequestSummary] = []
    @Published private(set) var extensionRegisteredStatus = "Checking..."
    @Published private(set) var fsKitVisibilityStatus = "Checking..."
    @Published private(set) var extensionPath = ""
    @Published private(set) var filesystemBundlePresent = false
    @Published private(set) var filesystemBundlePath = ""
    @Published private(set) var mountHelperPresent = false
    @Published private(set) var mountHelperPath = ""

    private let stateStore: SpiderwebFSKitStateStore

    init(stateStore: SpiderwebFSKitStateStore = SpiderwebFSKitStateStore()) {
        self.stateStore = stateStore
        refresh()
    }

    func refresh() {
        recentRequests = stateStore.recentRequests()
        extensionPath = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Extensions", isDirectory: true)
            .appendingPathComponent("SpiderwebFSKitExtension.appex", isDirectory: false)
            .path
        filesystemBundlePath = "/Library/Filesystems/spiderweb.fs"
        mountHelperPath = filesystemBundlePath + "/Contents/Resources/mount_spiderweb"
        filesystemBundlePresent = FileManager.default.fileExists(atPath: filesystemBundlePath)
        mountHelperPresent = FileManager.default.fileExists(atPath: mountHelperPath)
        if let snapshot = stateStore.nativeStatusSnapshot() {
            extensionRegisteredStatus = snapshot.registered ? "Yes" : "No"
        } else {
            extensionRegisteredStatus = "Checking..."
        }
        fsKitVisibilityStatus = "Checking..."
        Task {
            async let visibilityStatus = detectFSKitVisibility()
            if stateStore.nativeStatusSnapshot() == nil {
                extensionRegisteredStatus = await detectPlugInKitRegistration().label
            }
            fsKitVisibilityStatus = await visibilityStatus.label
        }
    }

    var requestDirectoryPath: String {
        stateStore.requestsDirectoryURL.path
    }

    private func detectPlugInKitRegistration() async -> SpiderwebStatusProbe {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = ["-m", "-i", "com.deanoc.spiderweb.fskit.app.extension"]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return .unknown("pluginkit unavailable")
        }

        process.waitUntilExit()
        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: outputData, as: UTF8.self)
        let errorOutput = String(decoding: errorData, as: UTF8.self)

        if process.terminationStatus == 0 || !output.isEmpty {
            return output.contains("com.deanoc.spiderweb.fskit.app.extension") ? .yes : .no
        }

        if !errorOutput.isEmpty {
            return .unknown(errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return .unknown("pluginkit probe failed")
    }

    private func detectFSKitVisibility() async -> SpiderwebStatusProbe {
        await withCheckedContinuation { continuation in
            FSClient.shared.fetchInstalledExtensions { modules, _ in
                let visible = modules?.contains { module in
                    module.bundleIdentifier == "com.deanoc.spiderweb.fskit.app.extension" && module.isEnabled
                } ?? false
                continuation.resume(returning: visible ? .yes : .no)
            }
        }
    }
}
