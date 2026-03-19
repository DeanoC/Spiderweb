import AppKit
import Foundation

enum SetupMode: String, CaseIterable, Identifiable {
    case localHost
    case mountExisting

    var id: String { rawValue }

    var title: String {
        switch self {
        case .localHost: return "Run Spiderweb on this Mac"
        case .mountExisting: return "Mount an Existing Spiderweb"
        }
    }

    var subtitle: String {
        switch self {
        case .localHost:
            return "Install the local Spiderweb service, enable the native file system, and mount local workspaces for Finder, Terminal, and agents."
        case .mountExisting:
            return "Enable the native file system and connect this Mac to an existing Spiderweb server."
        }
    }
}

struct NativeStatusSnapshot: Decodable {
    let version: UInt8
    let registered: Bool
    let moduleEnabled: Bool
    let ready: Bool
    let filesystemBundlePresent: Bool
    let mountHelperPresent: Bool
    let runtimeReady: Bool
    let updatedAtMs: Int64

    enum CodingKeys: String, CodingKey {
        case version
        case registered
        case moduleEnabled = "module_enabled"
        case ready
        case filesystemBundlePresent = "filesystem_bundle_present"
        case mountHelperPresent = "mount_helper_present"
        case runtimeReady = "runtime_ready"
        case updatedAtMs = "updated_at_ms"
    }
}

struct NativeStatusSummary {
    enum State {
        case unknown
        case notInstalled
        case installedNeedsEnable
        case ready
    }

    let state: State
    let detail: String
}

enum ServiceSummary {
    case unknown
    case notInstalled
    case installed

    var title: String {
        switch self {
        case .unknown: return "Unknown"
        case .notInstalled: return "Not installed"
        case .installed: return "Installed"
        }
    }

    var detail: String {
        switch self {
        case .unknown:
            return "Launchd status has not been checked from the CLI yet."
        case .notInstalled:
            return "Spiderweb is not set to start in the background for your user."
        case .installed:
            return "Spiderweb has a LaunchAgent and should start when you log in."
        }
    }
}

@MainActor
final class SpiderwebSetupModel: ObservableObject {
    private static let appGroupIdentifier = "group.com.deanoc.spiderweb.fskit"
    private static let systemSettingsURL = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!

    @Published var mode: SetupMode = .localHost
    @Published var localWorkspaceID = ""
    @Published var localMountpoint = "\(NSHomeDirectory())/Spiderweb/local"
    @Published var remoteServerURL = "ws://127.0.0.1:18790/"
    @Published var remoteWorkspaceID = ""
    @Published var remoteAuthToken = ""
    @Published var remoteMountpoint = "\(NSHomeDirectory())/Spiderweb/remote"
    @Published private(set) var nativeSummary = NativeStatusSummary(
        state: .unknown,
        detail: "Spiderweb has not written a native status snapshot yet.",
    )
    @Published private(set) var serviceSummary: ServiceSummary = .unknown
    @Published private(set) var lastStatusUpdate = "Not checked yet"

    init() {
        refresh()
    }

    func refresh() {
        nativeSummary = Self.loadNativeStatusSummary()
        serviceSummary = Self.loadServiceSummary()
        lastStatusUpdate = Self.makeUpdatedLabel(from: Self.loadNativeSnapshot()?.updatedAtMs)
    }

    func openSystemSettings() {
        NSWorkspace.shared.open(Self.systemSettingsURL)
    }

    func copyToClipboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    func openInTerminal(command: String, title: String) {
        let scriptURL = Self.commandScriptURL(named: title)
        let script = """
        #!/bin/bash
        export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
        clear
        echo "Spiderweb Setup"
        echo
        echo "\(title)"
        echo
        \(command)
        status=$?
        echo
        echo "Exit status: $status"
        echo
        read -n 1 -s -r -p "Press any key to close..."
        exit $status
        """

        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            NSWorkspace.shared.open(scriptURL)
        } catch {
            NSSound.beep()
        }
    }

    var installServiceCommand: String {
        "spiderweb-config config install-service\nspiderweb-config config service-status"
    }

    var inspectAuthCommand: String {
        "spiderweb-config auth status"
    }

    var createWorkspaceCommand: String {
        "spiderweb-control workspace_create '{\"name\":\"My Workspace\",\"vision\":\"Mounted workspace\"}'"
    }

    var listWorkspacesCommand: String {
        "spiderweb-control workspace_list"
    }

    var localMountCommand: String {
        let workspaceID = localWorkspaceID.isEmpty ? "<workspace-id>" : localWorkspaceID
        let escapedMountpoint = shellQuote(localMountpoint)
        return """
        SPIDERWEB_AUTH_TOKEN="$(jq -r '.admin_token' "$(spiderweb-config auth path)")" \\
        spiderweb-fs-mount \\
          --workspace-url ws://127.0.0.1:18790/ \\
          --workspace-id \(workspaceID) \\
          --mount-backend native \\
          mount \(escapedMountpoint)
        """
    }

    var remoteMountCommand: String {
        let workspaceID = remoteWorkspaceID.isEmpty ? "<workspace-id>" : remoteWorkspaceID
        let token = remoteAuthToken.isEmpty ? "<auth-token>" : remoteAuthToken
        let escapedMountpoint = shellQuote(remoteMountpoint)
        return """
        SPIDERWEB_AUTH_TOKEN=\(shellQuote(token)) \\
        spiderweb-fs-mount \\
          --workspace-url \(shellQuote(remoteServerURL)) \\
          --workspace-id \(workspaceID) \\
          --mount-backend native \\
          mount \(escapedMountpoint)
        """
    }

    private static func loadNativeStatusSummary() -> NativeStatusSummary {
        let bundleInstalled = FileManager.default.fileExists(atPath: "/Applications/Spiderweb.app")
        let filesystemInstalled = FileManager.default.fileExists(atPath: "/Library/Filesystems/spiderweb.fs")
        guard let snapshot = loadNativeSnapshot() else {
            if bundleInstalled || filesystemInstalled {
                return NativeStatusSummary(
                    state: .installedNeedsEnable,
                    detail: "Spiderweb is installed, but the file system has not reported a fresh status snapshot yet. If you just installed it, enable “Spiderweb file system” in System Settings and refresh.",
                )
            }
            return NativeStatusSummary(
                state: .notInstalled,
                detail: "Spiderweb is not installed yet on this Mac.",
            )
        }

        if snapshot.ready {
            return NativeStatusSummary(
                state: .ready,
                detail: "Native Spiderweb mounting is installed, enabled, and ready to use.",
            )
        }
        if snapshot.registered && !snapshot.moduleEnabled {
            return NativeStatusSummary(
                state: .installedNeedsEnable,
                detail: "Spiderweb is installed, but macOS still needs the file system enabled in System Settings.",
            )
        }
        if snapshot.filesystemBundlePresent || snapshot.runtimeReady {
            return NativeStatusSummary(
                state: .installedNeedsEnable,
                detail: "Spiderweb is installed, but setup still needs one or more macOS approval steps.",
            )
        }
        return NativeStatusSummary(
            state: .notInstalled,
            detail: "Spiderweb is not installed yet on this Mac.",
        )
    }

    private static func loadServiceSummary() -> ServiceSummary {
        let launchAgentPath = "\(NSHomeDirectory())/Library/LaunchAgents/spiderweb.plist"
        if FileManager.default.fileExists(atPath: launchAgentPath) {
            return .installed
        }
        return .notInstalled
    }

    private static func loadNativeSnapshot() -> NativeStatusSnapshot? {
        let paths = [
            appGroupContainerURL()?.appendingPathComponent("native-status.json").path,
            "\(NSHomeDirectory())/Library/Application Support/Spiderweb/native-status.json",
        ].compactMap { $0 }

        for path in paths {
            guard let data = FileManager.default.contents(atPath: path) else { continue }
            if let snapshot = try? JSONDecoder().decode(NativeStatusSnapshot.self, from: data) {
                return snapshot
            }
        }
        return nil
    }

    private static func appGroupContainerURL() -> URL? {
        if let shared = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            return shared
        }
        let fallback = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Group Containers", isDirectory: true)
            .appendingPathComponent(appGroupIdentifier, isDirectory: true)
        return fallback
    }

    private static func commandScriptURL(named title: String) -> URL {
        let safeName = title
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        let baseURL = appGroupContainerURL() ??
            URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let scriptsURL = baseURL.appendingPathComponent("SetupScripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: scriptsURL, withIntermediateDirectories: true)
        return scriptsURL.appendingPathComponent("\(safeName).command")
    }

    private static func makeUpdatedLabel(from timestampMs: Int64?) -> String {
        guard let timestampMs else { return "Not checked yet" }
        let date = Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000.0)
        return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }
}

private func shellQuote(_ value: String) -> String {
    if value.isEmpty {
        return "''"
    }
    let escaped = value.replacingOccurrences(of: "'", with: "'\"'\"'")
    return "'\(escaped)'"
}
