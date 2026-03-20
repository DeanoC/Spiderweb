import AppKit
import Darwin
import Foundation
import Security
import ServiceManagement
import SwiftUI

enum SpiderwebAppSection: String, CaseIterable, Identifiable {
    case overview
    case mounts
    case thisMac
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .mounts: return "Mounts"
        case .thisMac: return "This Mac"
        case .settings: return "Settings"
        }
    }

    var symbolName: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .mounts: return "externaldrive.connected.to.line.below"
        case .thisMac: return "macwindow"
        case .settings: return "gearshape"
        }
    }
}

enum SpiderwebOnboardingPath: String, CaseIterable, Identifiable {
    case localHost
    case remoteMount
    case remoteNode

    var id: String { rawValue }

    var title: String {
        switch self {
        case .localHost: return "Run Spiderweb on this Mac"
        case .remoteMount: return "Mount an Existing Spiderweb"
        case .remoteNode: return "Provide This Mac to a Remote Spiderweb"
        }
    }

    var subtitle: String {
        switch self {
        case .localHost:
            return "Install the local background service, manage workspaces, and create native mounts for tools and agents."
        case .remoteMount:
            return "Save and mount remote Spiderweb workspaces without running a local host."
        case .remoteNode:
            return "Pair this Mac to a remote Spiderweb and expose its filesystem as a node."
        }
    }

    var symbolName: String {
        switch self {
        case .localHost: return "desktopcomputer.and.sparkles"
        case .remoteMount: return "network.badge.shield.half.filled"
        case .remoteNode: return "externaldrive.badge.icloud"
        }
    }
}

enum SpiderwebSavedMountKind: String, Codable, CaseIterable, Identifiable {
    case local
    case remote

    var id: String { rawValue }
}

enum SpiderwebSavedMountAuthSource: String, Codable {
    case localRuntime = "local_runtime"
    case keychainSecret = "keychain_secret"
}

enum SpiderwebSavedMountState: String, Codable {
    case idle
    case mounted
    case error
}

enum SpiderwebRemoteNodeState: String, Codable {
    case idle
    case paired
    case attention
}

struct SpiderwebSavedMount: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var kind: SpiderwebSavedMountKind
    var serverURL: String
    var workspaceID: String
    var authSource: SpiderwebSavedMountAuthSource
    var mountpoint: String
    var createdAt: Date
    var updatedAt: Date
    var lastError: String?
    var lastMountState: SpiderwebSavedMountState

    static func makeDraft(kind: SpiderwebSavedMountKind, homeDirectory: String) -> SpiderwebSavedMount {
        .init(
            id: UUID().uuidString,
            name: kind == .local ? "Local Spiderweb" : "Remote Spiderweb",
            kind: kind,
            serverURL: kind == .local ? SpiderwebAppController.localServerURL : "",
            workspaceID: "",
            authSource: kind == .local ? .localRuntime : .keychainSecret,
            mountpoint: "\(homeDirectory)/Spiderweb/\(kind == .local ? "local" : "remote")",
            createdAt: Date(),
            updatedAt: Date(),
            lastError: nil,
            lastMountState: .idle
        )
    }
}

struct SpiderwebPairedRemoteNode: Codable {
    var remoteControlURL: String
    var nodeName: String
    var nodeID: String
    var publicBaseURL: String
    var exportPath: String
    var exportName: String
    var exportRO: Bool
    var leaseTTLMS: UInt64
    var heartbeatMS: UInt64
    var state: SpiderwebRemoteNodeState
    var lastError: String?
    var pairedAt: Date
    var updatedAt: Date
}

struct SpiderwebNativeStatusSnapshot: Decodable {
    let registered: Bool
    let moduleEnabled: Bool
    let ready: Bool
    let filesystemBundlePresent: Bool?
    let runtimeReady: Bool?
    let notes: [String]?

    enum CodingKeys: String, CodingKey {
        case registered
        case moduleEnabled = "module_enabled"
        case ready
        case filesystemBundlePresent = "filesystem_bundle_present"
        case runtimeReady = "runtime_ready"
        case notes
    }
}

struct SpiderwebServiceStatusSnapshot: Decodable {
    let manager: String
    let unitPath: String
    let installed: Bool
    let loaded: Bool
    let bind: String?
    let port: UInt16?
    let remoteReachable: Bool?

    enum CodingKeys: String, CodingKey {
        case manager
        case unitPath = "unit_path"
        case installed
        case loaded
        case bind
        case port
        case remoteReachable = "remote_reachable"
    }
}

struct SpiderwebAuthStatusSnapshot: Decodable {
    let path: String
    let adminPresent: Bool
    let userPresent: Bool
    let adminToken: String?
    let userToken: String?

    enum CodingKeys: String, CodingKey {
        case path
        case adminPresent = "admin_present"
        case userPresent = "user_present"
        case adminToken = "admin_token"
        case userToken = "user_token"
    }
}

struct SpiderwebRemoteNodeStatusSnapshot: Decodable {
    let enabled: Bool
    let remoteControlURL: String
    let nodeName: String
    let publicBaseURL: String
    let exportPath: String
    let exportName: String
    let exportRO: Bool
    let nodeID: String
    let leaseTTLMS: UInt64
    let heartbeatMS: UInt64
    let secretPresent: Bool

    enum CodingKeys: String, CodingKey {
        case enabled
        case remoteControlURL = "remote_control_url"
        case nodeName = "node_name"
        case publicBaseURL = "public_base_url"
        case exportPath = "export_path"
        case exportName = "export_name"
        case exportRO = "export_ro"
        case nodeID = "node_id"
        case leaseTTLMS = "lease_ttl_ms"
        case heartbeatMS = "heartbeat_ms"
        case secretPresent = "secret_present"
    }
}

struct SpiderwebWorkspaceSummary: Identifiable, Hashable {
    let id: String
    let name: String
    let status: String?
    let kind: String?
    let mountCount: Int

    var isMountable: Bool { mountCount > 0 }
}

struct SpiderwebMountEditorDraft {
    var editingID: String?
    var name: String = ""
    var kind: SpiderwebSavedMountKind = .local
    var serverURL: String = SpiderwebAppController.localServerURL
    var workspaceID: String = ""
    var mountpoint: String = "\(NSHomeDirectory())/Spiderweb/local"
    var authToken: String = ""

    mutating func populate(from mount: SpiderwebSavedMount, authToken: String?) {
        editingID = mount.id
        name = mount.name
        kind = mount.kind
        serverURL = mount.serverURL
        workspaceID = mount.workspaceID
        mountpoint = mount.mountpoint
        self.authToken = authToken ?? ""
    }

    mutating func reset(homeDirectory: String) {
        editingID = nil
        name = ""
        kind = .local
        serverURL = SpiderwebAppController.localServerURL
        workspaceID = ""
        mountpoint = "\(homeDirectory)/Spiderweb/local"
        authToken = ""
    }
}

struct SpiderwebRemoteNodeDraft {
    var remoteControlURL: String = "ws://127.0.0.1:18790/"
    var inviteToken: String = ""
    var nodeName: String = Host.current().localizedName ?? "This Mac"
    var publicBaseURL: String = "ws://127.0.0.1:18790"
    var exportPath: String = NSHomeDirectory()
    var exportName: String = "fs"
    var exportRO: Bool = false
    var leaseTTLMS: UInt64 = 15 * 60 * 1000
    var heartbeatMS: UInt64 = (15 * 60 * 1000) / 2
}

struct SpiderwebCommandResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

enum SpiderwebCommandTimeoutBehavior {
    case none
    case terminateProcessTree
}

struct SpiderwebBuildInfo: Codable {
    let version: String
    let gitCommit: String?
    let gitShortCommit: String?
    let gitDirty: Bool?
    let builtAtUTC: String?

    var versionLabel: String {
        if let short = gitShortCommit, !short.isEmpty {
            return "\(version) (\(short))"
        }
        return version
    }
}

struct SpiderwebAccessEndpoint: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let url: String
}

final class SpiderwebAppController: ObservableObject {
    static let localServerURL = "ws://127.0.0.1:18790/"
    private static let appGroupIdentifier = "group.com.deanoc.spiderweb.fskit"
    private static let savedMountsFilename = "saved-mounts.json"
    private static let pairedNodeFilename = "paired-node.json"
    private static let remoteMountSecretService = "com.deanoc.spiderweb.saved-mount"
    private static let spiderwebCredentialService = "spiderweb"
    private static let systemSettingsURL = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
    private static let nativeMountActionTimeout: TimeInterval = 20

    @Published var selectedSection: SpiderwebAppSection = .overview
    @Published var highlightedOnboardingPath: SpiderwebOnboardingPath = .localHost
    @Published var savedMounts: [SpiderwebSavedMount] = []
    @Published var pairedRemoteNode: SpiderwebPairedRemoteNode?
    @Published var mountEditor = SpiderwebMountEditorDraft()
    @Published var remoteNodeDraft = SpiderwebRemoteNodeDraft()
    @Published var serviceStatus: SpiderwebServiceStatusSnapshot?
    @Published var nativeStatus: SpiderwebNativeStatusSnapshot?
    @Published var authStatus: SpiderwebAuthStatusSnapshot?
    @Published var remoteNodeStatus: SpiderwebRemoteNodeStatusSnapshot?
    @Published var localWorkspaces: [SpiderwebWorkspaceSummary] = []
    @Published var activeMountpoints: Set<String> = []
    @Published var extensionRegistrationPaths: [String] = []
    @Published var launchAtLoginEnabled = false
    @Published var statusMessage: String?
    @Published var lastError: String?
    @Published var isBusy = false
    @Published var showingUninstallAlert = false
    @Published var buildInfo: SpiderwebBuildInfo

    init() {
        buildInfo = Self.fetchBuildInfo()
        loadPersistedState()
        refresh()
    }

    var menuBarSymbolName: String {
        if nativeStatus?.ready == true, !mountedSavedMounts.isEmpty {
            return "externaldrive.connected.to.line.below.fill"
        }
        if nativeStatus?.ready == true {
            return "externaldrive.badge.checkmark"
        }
        if hasSetupIssue {
            return "exclamationmark.triangle.fill"
        }
        return "externaldrive"
    }

    var mountedSavedMounts: [SpiderwebSavedMount] {
        savedMounts.filter { activeMountpoints.contains($0.mountpoint) }
    }

    var mountableLocalWorkspaces: [SpiderwebWorkspaceSummary] {
        localWorkspaces.filter { $0.kind != "system_builtin" && $0.isMountable }
    }

    var nonMountableLocalWorkspaces: [SpiderwebWorkspaceSummary] {
        localWorkspaces.filter { $0.kind != "system_builtin" && !$0.isMountable }
    }

    var hasSetupIssue: Bool {
        if nativeStatus?.ready != true { return true }
        if highlightedOnboardingPath == .localHost {
            return serviceStatus?.loaded != true
        }
        return false
    }

    var hasDuplicateExtensionRegistrations: Bool {
        extensionRegistrationPaths.contains { !$0.hasPrefix("/Applications/Spiderweb.app/") }
    }

    var nativeStatusHeadline: String {
        if nativeStatus?.ready == true {
            return "Ready"
        }
        if nativeStatus?.registered == true {
            return nativeStatus?.moduleEnabled == true ? "Almost ready" : "Needs enablement"
        }
        return "Not ready"
    }

    var nativeStatusDetailText: String {
        guard let nativeStatus else {
            return "Install and enable the native Spiderweb file system to mount workspaces in Finder."
        }
        if nativeStatus.ready {
            return "Spiderweb file system is installed and enabled."
        }
        if nativeStatus.registered && !nativeStatus.moduleEnabled {
            if hasDuplicateExtensionRegistrations {
                return "Spiderweb file system is installed, but macOS is also seeing another Spiderweb build. In System Settings -> General -> Login Items & Extensions -> File System Extensions, enable “Spiderweb file system” for /Applications/Spiderweb.app and disable any older Spiderweb FSKit entry."
            }
            return "Spiderweb file system is installed, but macOS has not enabled it yet. Open System Settings -> General -> Login Items & Extensions -> File System Extensions and turn on “Spiderweb file system”."
        }
        if nativeStatus.registered {
            return "Spiderweb file system is registered, but macOS still needs one more enablement step before native mounts will work."
        }
        return "Install the Spiderweb file system, then open System Settings -> General -> Login Items & Extensions -> File System Extensions and enable “Spiderweb file system”."
    }

    var nativeEnablementSteps: [String] {
        var steps = [
            "Open System Settings -> General -> Login Items & Extensions -> File System Extensions.",
            "Turn on “Spiderweb file system”.",
        ]
        if hasDuplicateExtensionRegistrations {
            steps.append("If you also see an older Spiderweb FSKit entry, disable the older one and keep the /Applications/Spiderweb.app entry enabled.")
        }
        return steps
    }

    var diagnosticsSummary: String {
        let serviceLine: String
        if let serviceStatus {
            let bind = serviceStatus.bind ?? "unknown"
            let port = serviceStatus.port.map(String.init) ?? "unknown"
            let remoteReachable = serviceStatus.remoteReachable.map(String.init) ?? "unknown"
            serviceLine = "service installed=\(serviceStatus.installed) loaded=\(serviceStatus.loaded) bind=\(bind):\(port) remote_reachable=\(remoteReachable)"
        } else {
            serviceLine = "service unknown"
        }

        let nativeLine: String
        if let nativeStatus {
            nativeLine = "native ready=\(nativeStatus.ready) registered=\(nativeStatus.registered) module_enabled=\(nativeStatus.moduleEnabled)"
        } else {
            nativeLine = "native unknown"
        }
        let registrationLine = "extension registrations=\(extensionRegistrationPaths.count)"

        let authLine: String
        if let authStatus {
            authLine = "auth access_present=\(authStatus.adminPresent)"
        } else {
            authLine = "auth unknown"
        }

        let remoteNodeLine: String
        if let remoteNodeStatus {
            remoteNodeLine = "remote-node enabled=\(remoteNodeStatus.enabled) secret_present=\(remoteNodeStatus.secretPresent)"
        } else {
            remoteNodeLine = "remote-node unknown"
        }

        let buildLine = "version \(buildInfo.versionLabel)"
        let buildTimeLine = "built_at \(buildInfo.builtAtUTC ?? "unknown")"
        let dirtyLine = "git_dirty \(buildInfo.gitDirty ?? false)"
        let bundleLine = "app \(Bundle.main.bundlePath)"
        let configPath = "spiderweb-config \(Self.resolveExecutable(named: "spiderweb-config"))"
        return [
            buildLine,
            buildTimeLine,
            dirtyLine,
            bundleLine,
            configPath,
            serviceLine,
            nativeLine,
            registrationLine,
            authLine,
            remoteNodeLine,
        ].joined(separator: "\n")
    }

    var localAccessEndpoints: [SpiderwebAccessEndpoint] {
        let port = Int(serviceStatus?.port ?? 18790)
        var endpoints: [SpiderwebAccessEndpoint] = [
            .init(
                id: "localhost",
                title: "Local-only URL",
                detail: "Use this on the same Mac. Other machines cannot reach 127.0.0.1 on your Mac.",
                url: "ws://127.0.0.1:\(port)/"
            )
        ]

        if serviceStatus?.remoteReachable == false {
            return endpoints
        }

        let networkHostnames = Self.discoverLocalHostnames()
        for hostname in networkHostnames {
            endpoints.append(
                .init(
                    id: "host-\(hostname)",
                    title: "Network hostname",
                    detail: "Works from another machine on the same network if mDNS or local DNS resolves this Mac.",
                    url: "ws://\(hostname):\(port)/"
                )
            )
        }

        let networkIPv4s = Self.discoverLocalIPv4Addresses()
        for address in networkIPv4s {
            endpoints.append(
                .init(
                    id: "ipv4-\(address)",
                    title: "Network IPv4",
                    detail: "Direct LAN address for another Mac or tool to connect to this Spiderweb service.",
                    url: "ws://\(address):\(port)/"
                )
            )
        }

        return endpoints
    }

    func refresh() {
        Task {
            let refreshedMounts = Self.loadSavedMounts()
            let pairedNode = Self.loadPairedRemoteNode()
            let serviceStatus = Self.fetchServiceStatus()
            let nativeStatus = Self.fetchNativeStatus()
            let authStatus = Self.fetchAuthStatus(revealTokens: true)
            let remoteNodeStatus = Self.fetchRemoteNodeStatus()
            let activeMountpoints = Self.fetchActiveMountpoints()
            let extensionRegistrationPaths = Self.fetchExtensionRegistrationPaths()
            let workspaces = Self.fetchLocalWorkspaces(using: authStatus)
            let launchAtLoginEnabled = Self.fetchLaunchAtLoginEnabled()
            let buildInfo = Self.fetchBuildInfo()

            let mergedMounts = refreshedMounts.map { mount in
                var next = mount
                next.lastMountState = activeMountpoints.contains(mount.mountpoint) ? .mounted : .idle
                return next
            }

            await MainActor.run {
                self.savedMounts = mergedMounts
                self.pairedRemoteNode = pairedNode
                self.serviceStatus = serviceStatus
                self.nativeStatus = nativeStatus
                self.authStatus = authStatus
                self.remoteNodeStatus = remoteNodeStatus
                self.activeMountpoints = activeMountpoints
                self.extensionRegistrationPaths = extensionRegistrationPaths
                self.localWorkspaces = workspaces
                self.launchAtLoginEnabled = launchAtLoginEnabled
                self.buildInfo = buildInfo
                if Self.shouldAutofillRemoteNodePublicBaseURL(current: self.remoteNodeDraft.publicBaseURL),
                   let suggested = Self.preferredRemoteNodePublicBaseURL(from: serviceStatus) {
                    self.remoteNodeDraft.publicBaseURL = suggested
                }
                self.statusMessage = "Last refreshed \(Self.relativeTimestampLabel())"
            }
        }
    }

    func openSystemSettings() {
        NSWorkspace.shared.open(Self.systemSettingsURL)
    }

    func reveal(mount: SpiderwebSavedMount) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: mount.mountpoint)])
    }

    func copyToClipboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    func copyDiagnostics() {
        copyToClipboard(diagnosticsSummary)
        statusMessage = "Copied diagnostics"
    }

    func mountCommand(for mount: SpiderwebSavedMount) -> String {
        let tokenPrefix: String
        switch mount.authSource {
        case .localRuntime:
            tokenPrefix = "SPIDERWEB_AUTH_TOKEN=\"$(spiderweb-config auth status --json --reveal | jq -r '.admin_token')\" \\\n"
        case .keychainSecret:
            tokenPrefix = "SPIDERWEB_AUTH_TOKEN='<stored-in-keychain>' \\\n"
        }
        let trimmedWorkspaceID = mount.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let workspaceLine = trimmedWorkspaceID.isEmpty ? "" : "  --workspace-id \(trimmedWorkspaceID) \\\n"
        return """
        \(tokenPrefix)spiderweb-fs-mount \\
          --workspace-url '\(mount.serverURL)' \\
        \(workspaceLine)  --mount-backend native \\
          mount '\(mount.mountpoint)'
        """
    }

    func copyMountCommand(for mount: SpiderwebSavedMount) {
        copyToClipboard(mountCommand(for: mount))
    }

    func beginNewMount(kind: SpiderwebSavedMountKind) {
        mountEditor = SpiderwebMountEditorDraft()
        mountEditor.kind = kind
        mountEditor.serverURL = kind == .local ? Self.localServerURL : ""
        if kind == .local {
            guard let workspace = mountableLocalWorkspaces.first else {
                lastError = "Create a local workspace first."
                highlightedOnboardingPath = .localHost
                selectedSection = .thisMac
                return
            }
            mountEditor.name = workspace.name
            mountEditor.workspaceID = workspace.id
            mountEditor.mountpoint = "\(NSHomeDirectory())/Spiderweb/\(workspace.id)"
        } else {
            mountEditor.mountpoint = "\(NSHomeDirectory())/Spiderweb/remote"
        }
        selectedSection = .mounts
    }

    func editMount(_ mount: SpiderwebSavedMount) {
        mountEditor.populate(from: mount, authToken: Self.loadSecret(service: Self.remoteMountSecretService, account: mount.id))
        selectedSection = .mounts
    }

    func saveMountDraft() {
        lastError = nil
        let trimmedWorkspaceID = mountEditor.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        var next = if let editingID = mountEditor.editingID,
                      let existing = savedMounts.first(where: { $0.id == editingID }) {
            existing
        } else {
            SpiderwebSavedMount.makeDraft(kind: mountEditor.kind, homeDirectory: NSHomeDirectory())
        }

        let isMounted = activeMountpoints.contains(next.mountpoint)
        if isMounted, mountEditor.editingID != nil {
            let connectionChanged = next.kind != mountEditor.kind ||
                next.serverURL != mountEditor.serverURL ||
                next.workspaceID != mountEditor.workspaceID ||
                next.mountpoint != mountEditor.mountpoint
            if connectionChanged {
                lastError = "Unmount this saved mount before changing its server, workspace, or mountpoint."
                return
            }
        }

        next.name = mountEditor.name.isEmpty ? (mountEditor.kind == .local ? "Local Spiderweb" : "Remote Spiderweb") : mountEditor.name
        next.kind = mountEditor.kind
        next.serverURL = mountEditor.kind == .local ? Self.localServerURL : mountEditor.serverURL
        if mountEditor.kind == .local {
            guard !trimmedWorkspaceID.isEmpty else {
                lastError = "Local mounts need a real workspace. Create one in This Mac first."
                return
            }
            if let workspace = localWorkspaces.first(where: { $0.id == trimmedWorkspaceID }),
               workspace.kind == "system_builtin" {
                lastError = "That workspace is reserved. Create a normal workspace first."
                return
            }
        } else if trimmedWorkspaceID.isEmpty {
            lastError = "Remote mounts need a workspace ID."
            return
        }
        next.workspaceID = trimmedWorkspaceID
        next.mountpoint = mountEditor.mountpoint
        next.authSource = mountEditor.kind == .local ? .localRuntime : .keychainSecret
        next.updatedAt = Date()

        if next.kind == .remote {
            guard !mountEditor.authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || Self.loadSecret(service: Self.remoteMountSecretService, account: next.id) != nil else {
                lastError = "Remote mounts need an auth token."
                return
            }
            if !mountEditor.authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                do {
                    try Self.storeSecret(service: Self.remoteMountSecretService, account: next.id, value: mountEditor.authToken)
                } catch {
                    lastError = "Could not save the remote mount token in Keychain."
                    return
                }
            }
        } else {
            Self.deleteSecret(service: Self.remoteMountSecretService, account: next.id)
        }

        if let index = savedMounts.firstIndex(where: { $0.id == next.id }) {
            savedMounts[index] = next
        } else {
            savedMounts.append(next)
        }
        persistSavedMounts()
        mountEditor.reset(homeDirectory: NSHomeDirectory())
        statusMessage = "Saved mount “\(next.name)”"
    }

    func deleteMount(_ mount: SpiderwebSavedMount) {
        savedMounts.removeAll { $0.id == mount.id }
        Self.deleteSecret(service: Self.remoteMountSecretService, account: mount.id)
        persistSavedMounts()
        statusMessage = "Deleted saved mount “\(mount.name)”"
    }

    func installLocalService() {
        runSimpleAction(message: "Installed Spiderweb background service") {
            _ = try Self.runCLI("spiderweb-config", arguments: ["config", "install-service"])
        }
    }

    func uninstallLocalService() {
        runSimpleAction(message: "Removed Spiderweb background service") {
            _ = try Self.runCLI("spiderweb-config", arguments: ["config", "uninstall-service"])
        }
    }

    func uninstallSpiderweb() {
        showingUninstallAlert = false
        isBusy = true
        lastError = nil
        statusMessage = "Uninstalling Spiderweb…"

        Task.detached(priority: .userInitiated) {
            do {
                for mountpoint in Self.fetchActiveMountpoints() {
                    Self.bestEffortUnmount(mountpoint)
                }

                try? Self.applyLaunchAtLogin(enabled: false)
                _ = try? Self.runCLI("spiderweb-config", arguments: ["config", "remote-node", "clear"])
                _ = try? Self.runCLI("spiderweb-config", arguments: ["config", "uninstall-service"])
                _ = try? Self.runCLI("spiderweb-config", arguments: ["config", "uninstall-fs-extension"])

                Self.deleteAllSecrets(service: Self.remoteMountSecretService)
                Self.deleteAllSecrets(service: Self.spiderwebCredentialService)

                let scriptURL = try Self.writeSelfUninstallScript()
                try Self.launchDetachedProcess(executableURL: scriptURL, arguments: [])

                await MainActor.run {
                    NSApp.terminate(nil)
                }
            } catch {
                await MainActor.run {
                    self.isBusy = false
                    self.lastError = Self.describe(error: error)
                }
            }
        }
    }

    func installFileSystem() {
        isBusy = true
        lastError = nil
        Task.detached(priority: .userInitiated) {
            do {
                _ = try Self.runCLI("spiderweb-config", arguments: ["config", "install-fs-extension"])
                let refreshedMounts = Self.loadSavedMounts()
                let pairedNode = Self.loadPairedRemoteNode()
                let serviceStatus = Self.fetchServiceStatus()
                let nativeStatus = Self.fetchNativeStatus()
                let authStatus = Self.fetchAuthStatus(revealTokens: true)
                let remoteNodeStatus = Self.fetchRemoteNodeStatus()
                let activeMountpoints = Self.fetchActiveMountpoints()
                let extensionRegistrationPaths = Self.fetchExtensionRegistrationPaths()
                let workspaces = Self.fetchLocalWorkspaces(using: authStatus)
                let mergedMounts = refreshedMounts.map { mount -> SpiderwebSavedMount in
                    var next = mount
                    next.lastMountState = activeMountpoints.contains(mount.mountpoint) ? .mounted : .idle
                    return next
                }
                let message = Self.installFileSystemStatusMessage(
                    nativeStatus: nativeStatus,
                    extensionRegistrationPaths: extensionRegistrationPaths
                )
                await MainActor.run {
                    self.isBusy = false
                    self.savedMounts = mergedMounts
                    self.pairedRemoteNode = pairedNode
                    self.serviceStatus = serviceStatus
                    self.nativeStatus = nativeStatus
                    self.authStatus = authStatus
                    self.remoteNodeStatus = remoteNodeStatus
                    self.activeMountpoints = activeMountpoints
                    self.extensionRegistrationPaths = extensionRegistrationPaths
                    self.localWorkspaces = workspaces
                    self.statusMessage = message
                }
            } catch {
                await MainActor.run {
                    self.isBusy = false
                    self.lastError = Self.describe(error: error)
                }
            }
        }
    }

    func refreshWorkspaces() {
        Task {
            let auth = Self.fetchAuthStatus(revealTokens: true)
            let workspaces = Self.fetchLocalWorkspaces(using: auth)
            await MainActor.run {
                self.authStatus = auth
                self.localWorkspaces = workspaces
            }
        }
    }

    func createWorkspace(name: String, vision: String) {
        isBusy = true
        lastError = nil
        Task.detached(priority: .userInitiated) {
            do {
                guard let auth = Self.fetchAuthStatus(revealTokens: true), let adminToken = auth.adminToken else {
                    throw SpiderwebAppError.message("Local Spiderweb auth tokens are not available yet.")
                }
                let payload = try Self.jsonString([
                    "name": name,
                    "vision": vision,
                    "template_id": "dev",
                    "activate": false,
                ])
                let result = try Self.runCLI(
                    "spiderweb-control",
                    arguments: ["--url", Self.localServerURL, "--auth-token", adminToken, "workspace_up", payload]
                )
                let response = try Self.extractControlPayloadObject(from: result.stdout)
                let workspaceID = (response["workspace_id"] ?? response["project_id"]) as? String ?? name
                let created = response["created"] as? Bool ?? false
                let workspaceObject = response["workspace"] as? [String: Any]
                let mountCount = (workspaceObject?["mount_count"] as? Int) ?? (workspaceObject?["mount_count"] as? NSNumber)?.intValue ?? 0

                let refreshedMounts = Self.loadSavedMounts()
                let pairedNode = Self.loadPairedRemoteNode()
                let serviceStatus = Self.fetchServiceStatus()
                let nativeStatus = Self.fetchNativeStatus()
                let authStatus = Self.fetchAuthStatus(revealTokens: true)
                let remoteNodeStatus = Self.fetchRemoteNodeStatus()
                let activeMountpoints = Self.fetchActiveMountpoints()
                let extensionRegistrationPaths = Self.fetchExtensionRegistrationPaths()
                let workspaces = Self.fetchLocalWorkspaces(using: authStatus)
                let mergedMounts = refreshedMounts.map { mount -> SpiderwebSavedMount in
                    var next = mount
                    next.lastMountState = activeMountpoints.contains(mount.mountpoint) ? .mounted : .idle
                    return next
                }
                let statusMessage: String
                if mountCount > 0 {
                    statusMessage = created
                        ? "Created workspace “\(name)” as \(workspaceID)"
                        : "Updated existing workspace “\(name)” (\(workspaceID))"
                } else {
                    statusMessage = created
                        ? "Created workspace “\(name)” as \(workspaceID), but it is not mountable yet because the local filesystem node is not ready."
                        : "Updated existing workspace “\(name)” (\(workspaceID)), but it is still not mountable because the local filesystem node is not ready."
                }

                await MainActor.run {
                    self.isBusy = false
                    self.savedMounts = mergedMounts
                    self.pairedRemoteNode = pairedNode
                    self.serviceStatus = serviceStatus
                    self.nativeStatus = nativeStatus
                    self.authStatus = authStatus
                    self.remoteNodeStatus = remoteNodeStatus
                    self.activeMountpoints = activeMountpoints
                    self.extensionRegistrationPaths = extensionRegistrationPaths
                    self.localWorkspaces = workspaces
                    self.statusMessage = statusMessage
                }
            } catch {
                await MainActor.run {
                    self.isBusy = false
                    self.lastError = Self.describe(error: error)
                }
            }
        }
    }

    func createSavedLocalMount(for workspace: SpiderwebWorkspaceSummary) {
        guard workspace.kind != "system_builtin" else {
            lastError = "That workspace is reserved. Create a normal workspace first."
            selectedSection = .thisMac
            return
        }
        guard workspace.isMountable else {
            lastError = "This workspace is not mountable yet because the local filesystem node is not ready."
            selectedSection = .thisMac
            return
        }
        var draft = SpiderwebMountEditorDraft()
        draft.kind = .local
        draft.name = workspace.name
        draft.serverURL = Self.localServerURL
        draft.workspaceID = workspace.id
        draft.mountpoint = "\(NSHomeDirectory())/Spiderweb/\(workspace.id)"
        mountEditor = draft
        selectedSection = .mounts
    }

    func deleteWorkspace(_ workspace: SpiderwebWorkspaceSummary) {
        guard workspace.kind != "system_builtin" else {
            lastError = "That workspace is reserved and cannot be deleted."
            selectedSection = .thisMac
            return
        }

        let linkedMounts = savedMounts.filter { $0.kind == .local && $0.workspaceID == workspace.id }
        if linkedMounts.contains(where: { activeMountpoints.contains($0.mountpoint) }) {
            lastError = "Unmount saved local mounts for “\(workspace.name)” before deleting the workspace."
            selectedSection = .mounts
            return
        }

        isBusy = true
        lastError = nil
        Task.detached(priority: .userInitiated) {
            do {
                guard let auth = Self.fetchAuthStatus(revealTokens: true), let adminToken = auth.adminToken else {
                    throw SpiderwebAppError.message("Local Spiderweb auth tokens are not available yet.")
                }
                let payload = try Self.jsonString([
                    "workspace_id": workspace.id,
                ])
                _ = try Self.runCLI(
                    "spiderweb-control",
                    arguments: ["--url", Self.localServerURL, "--auth-token", adminToken, "workspace_delete", payload]
                )

                var refreshedMounts = Self.loadSavedMounts()
                refreshedMounts.removeAll { $0.kind == .local && $0.workspaceID == workspace.id }
                Self.persistSavedMounts(refreshedMounts)

                let pairedNode = Self.loadPairedRemoteNode()
                let serviceStatus = Self.fetchServiceStatus()
                let nativeStatus = Self.fetchNativeStatus()
                let authStatus = Self.fetchAuthStatus(revealTokens: true)
                let remoteNodeStatus = Self.fetchRemoteNodeStatus()
                let activeMountpoints = Self.fetchActiveMountpoints()
                let extensionRegistrationPaths = Self.fetchExtensionRegistrationPaths()
                let workspaces = Self.fetchLocalWorkspaces(using: authStatus)
                let mergedMounts = refreshedMounts.map { mount -> SpiderwebSavedMount in
                    var next = mount
                    next.lastMountState = activeMountpoints.contains(mount.mountpoint) ? .mounted : .idle
                    return next
                }

                await MainActor.run {
                    self.isBusy = false
                    self.savedMounts = mergedMounts
                    self.pairedRemoteNode = pairedNode
                    self.serviceStatus = serviceStatus
                    self.nativeStatus = nativeStatus
                    self.authStatus = authStatus
                    self.remoteNodeStatus = remoteNodeStatus
                    self.activeMountpoints = activeMountpoints
                    self.extensionRegistrationPaths = extensionRegistrationPaths
                    self.localWorkspaces = workspaces
                    self.statusMessage = "Deleted workspace “\(workspace.name)”"
                }
            } catch {
                await MainActor.run {
                    self.isBusy = false
                    self.lastError = Self.describe(error: error)
                }
            }
        }
    }

    func mount(_ mount: SpiderwebSavedMount) {
        runMountAction(on: mount, isMounting: true)
    }

    func unmount(_ mount: SpiderwebSavedMount) {
        runMountAction(on: mount, isMounting: false)
    }

    func pairRemoteNode() {
        let draft = remoteNodeDraft
        runSimpleAction(message: "Paired this Mac to the remote Spiderweb") {
            let fsURL = Self.derivedRemoteFsURL(from: draft.publicBaseURL)
            let joinPayload = try Self.jsonString([
                "invite_token": draft.inviteToken,
                "node_name": draft.nodeName,
                "fs_url": fsURL,
                "lease_ttl_ms": draft.leaseTTLMS,
            ])
            let joinResult = try Self.runCLI(
                "spiderweb-control",
                arguments: ["--url", draft.remoteControlURL, "node_join", joinPayload]
            )
            let joinPayloadObject = try Self.extractControlPayloadObject(from: joinResult.stdout)
            guard
                let nodeID = joinPayloadObject["node_id"] as? String,
                let nodeSecret = joinPayloadObject["node_secret"] as? String
            else {
                throw SpiderwebAppError.message("Remote Spiderweb did not return a node id and node secret.")
            }

            var args = [
                "config", "remote-node", "set",
                "--remote-control-url", draft.remoteControlURL,
                "--node-name", draft.nodeName,
                "--public-base-url", draft.publicBaseURL,
                "--export-path", draft.exportPath,
                "--export-name", draft.exportName,
                "--node-id", nodeID,
                "--node-secret", nodeSecret,
                "--lease-ttl-ms", String(draft.leaseTTLMS),
                "--heartbeat-ms", String(draft.heartbeatMS),
            ]
            if draft.exportRO {
                args.append("--read-only")
            }
            _ = try Self.runCLI("spiderweb-config", arguments: args)

            let paired = SpiderwebPairedRemoteNode(
                remoteControlURL: draft.remoteControlURL,
                nodeName: draft.nodeName,
                nodeID: nodeID,
                publicBaseURL: draft.publicBaseURL,
                exportPath: draft.exportPath,
                exportName: draft.exportName,
                exportRO: draft.exportRO,
                leaseTTLMS: draft.leaseTTLMS,
                heartbeatMS: draft.heartbeatMS,
                state: .paired,
                lastError: nil,
                pairedAt: Date(),
                updatedAt: Date()
            )
            Self.persistPairedRemoteNode(paired)
        }
    }

    func unpairRemoteNode() {
        runSimpleAction(message: "Disconnected this Mac from the remote Spiderweb") {
            guard let paired = Self.loadPairedRemoteNode() else { return }
            guard let nodeSecret = Self.loadSecret(
                service: Self.spiderwebCredentialService,
                account: Self.remoteNodeSecretAccount(for: paired.nodeID)
            ) else {
                throw SpiderwebAppError.message("The remote node secret is unavailable. Use Forget Locally if the remote pairing is already gone.")
            }
            let deletePayload = try Self.jsonString([
                "node_id": paired.nodeID,
                "node_secret": nodeSecret,
            ])
            _ = try Self.runCLI(
                "spiderweb-control",
                arguments: ["--url", paired.remoteControlURL, "node_delete", deletePayload]
            )
            _ = try Self.runCLI("spiderweb-config", arguments: ["config", "remote-node", "clear"])
            Self.deletePairedRemoteNode()
        }
    }

    func clearRemoteNodePairing() {
        runSimpleAction(message: "Cleared remote-node pairing on this Mac") {
            _ = try Self.runCLI("spiderweb-config", arguments: ["config", "remote-node", "clear"])
            Self.deletePairedRemoteNode()
        }
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        isBusy = true
        lastError = nil
        Task.detached(priority: .userInitiated) {
            do {
                try Self.applyLaunchAtLogin(enabled: enabled)
                await MainActor.run {
                    self.isBusy = false
                    self.launchAtLoginEnabled = enabled
                    self.statusMessage = enabled ? "Spiderweb will open at login" : "Spiderweb will no longer open at login"
                }
            } catch {
                let actual = Self.fetchLaunchAtLoginEnabled()
                await MainActor.run {
                    self.isBusy = false
                    self.launchAtLoginEnabled = actual
                    self.lastError = Self.describe(error: error)
                }
            }
        }
    }

    private func runMountAction(on mount: SpiderwebSavedMount, isMounting: Bool) {
        runSimpleAction(message: isMounting ? "Mounted “\(mount.name)”" : "Unmounted “\(mount.name)”") {
            if isMounting {
                let trimmedWorkspaceID = mount.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
                let revealedAuth = Self.fetchAuthStatus(revealTokens: true)
                if mount.kind == .local {
                    if trimmedWorkspaceID.isEmpty {
                        throw SpiderwebAppError.message("Local mounts need a real workspace. Create one in This Mac first.")
                    }
                    if trimmedWorkspaceID == "system" {
                        throw SpiderwebAppError.message("That workspace is reserved. Create a normal workspace first.")
                    }
                    guard let auth = revealedAuth, auth.adminToken != nil else {
                        throw SpiderwebAppError.message("Local Spiderweb auth token is unavailable.")
                    }
                    let workspaces = Self.fetchLocalWorkspaces(using: auth)
                    guard let workspace = workspaces.first(where: { $0.id == trimmedWorkspaceID }) else {
                        throw SpiderwebAppError.message("This saved mount points to workspace “\(trimmedWorkspaceID)”, but that workspace no longer exists. Delete or edit the saved mount, or recreate the workspace in This Mac.")
                    }
                    guard workspace.isMountable else {
                        throw SpiderwebAppError.message("Workspace “\(workspace.name)” is not mountable yet because the local filesystem node is not ready.")
                    }
                } else if trimmedWorkspaceID.isEmpty {
                    throw SpiderwebAppError.message("This saved remote mount is missing a workspace ID.")
                }
                var env: [String: String] = [:]
                switch mount.authSource {
                case .localRuntime:
                    guard let adminToken = revealedAuth?.adminToken else {
                        throw SpiderwebAppError.message("Local Spiderweb auth token is unavailable.")
                    }
                    env["SPIDERWEB_AUTH_TOKEN"] = adminToken
                case .keychainSecret:
                    guard let token = Self.loadSecret(service: Self.remoteMountSecretService, account: mount.id) else {
                        throw SpiderwebAppError.message("No remote auth token is stored for this mount.")
                    }
                    env["SPIDERWEB_AUTH_TOKEN"] = token
                }
                _ = try Self.runCLI(
                    "spiderweb-fs-mount",
                    arguments: [
                        "--workspace-url", mount.serverURL,
                        "--mount-backend", "native",
                    ] + (trimmedWorkspaceID.isEmpty ? [] : ["--workspace-id", trimmedWorkspaceID]) + [
                        "mount",
                        mount.mountpoint,
                    ],
                    environment: env,
                    timeout: Self.nativeMountActionTimeout,
                    timeoutBehavior: .terminateProcessTree
                )
            } else {
                let diskutilResult = try? Self.runCLI("diskutil", arguments: ["unmount", mount.mountpoint])
                if diskutilResult?.status != 0 {
                    _ = try Self.runCLI("umount", arguments: [mount.mountpoint])
                }
            }
        }
    }

    private func runSimpleAction(message: String, operation: @escaping () throws -> Void) {
        isBusy = true
        lastError = nil
        Task.detached(priority: .userInitiated) {
            do {
                try operation()
                let refreshedMounts = Self.loadSavedMounts()
                let pairedNode = Self.loadPairedRemoteNode()
                let serviceStatus = Self.fetchServiceStatus()
                let nativeStatus = Self.fetchNativeStatus()
                let authStatus = Self.fetchAuthStatus(revealTokens: true)
                let remoteNodeStatus = Self.fetchRemoteNodeStatus()
                let activeMountpoints = Self.fetchActiveMountpoints()
                let extensionRegistrationPaths = Self.fetchExtensionRegistrationPaths()
                let workspaces = Self.fetchLocalWorkspaces(using: authStatus)
                let mergedMounts = refreshedMounts.map { mount -> SpiderwebSavedMount in
                    var next = mount
                    next.lastMountState = activeMountpoints.contains(mount.mountpoint) ? .mounted : .idle
                    return next
                }
                await MainActor.run {
                    self.isBusy = false
                    self.savedMounts = mergedMounts
                    self.pairedRemoteNode = pairedNode
                    self.serviceStatus = serviceStatus
                    self.nativeStatus = nativeStatus
                    self.authStatus = authStatus
                    self.remoteNodeStatus = remoteNodeStatus
                    self.activeMountpoints = activeMountpoints
                    self.extensionRegistrationPaths = extensionRegistrationPaths
                    self.localWorkspaces = workspaces
                    self.statusMessage = message
                }
            } catch {
                await MainActor.run {
                    self.isBusy = false
                    self.lastError = Self.describe(error: error)
                }
            }
        }
    }

    private func loadPersistedState() {
        savedMounts = Self.loadSavedMounts()
        pairedRemoteNode = Self.loadPairedRemoteNode()
    }

    private func persistSavedMounts() {
        Self.persistSavedMounts(savedMounts)
    }

    private static func relativeTimestampLabel() -> String {
        RelativeDateTimeFormatter().localizedString(for: Date(), relativeTo: Date())
    }

    private static func fetchServiceStatus() -> SpiderwebServiceStatusSnapshot? {
        guard let result = try? runCLI("spiderweb-config", arguments: ["config", "service-status", "--json"]) else {
            return fallbackServiceStatus()
        }
        if let parsed = decodeJSON(SpiderwebServiceStatusSnapshot.self, from: result.stdout) {
            return parsed
        }
        return parseServiceStatusFromText(result.stdout) ?? fallbackServiceStatus()
    }

    private static func fetchNativeStatus() -> SpiderwebNativeStatusSnapshot? {
        if let result = try? runCLI("spiderweb-config", arguments: ["config", "fs-extension-status", "--json"]),
           let parsed = decodeJSON(SpiderwebNativeStatusSnapshot.self, from: result.stdout) {
            return parsed
        }
        guard let snapshotURL = appGroupContainerURL()?.appendingPathComponent("native-status.json"),
              let data = try? Data(contentsOf: snapshotURL)
        else {
            return nil
        }
        return try? JSONDecoder().decode(SpiderwebNativeStatusSnapshot.self, from: data)
    }

    private static func fetchAuthStatus(revealTokens: Bool) -> SpiderwebAuthStatusSnapshot? {
        var args = ["auth", "status", "--json"]
        if revealTokens {
            args.append("--reveal")
        }
        guard let result = try? runCLI("spiderweb-config", arguments: args) else {
            return nil
        }
        return decodeJSON(SpiderwebAuthStatusSnapshot.self, from: result.stdout)
    }

    private static func fetchRemoteNodeStatus() -> SpiderwebRemoteNodeStatusSnapshot? {
        guard let result = try? runCLI("spiderweb-config", arguments: ["config", "remote-node", "status", "--json"]) else {
            return nil
        }
        return decodeJSON(SpiderwebRemoteNodeStatusSnapshot.self, from: result.stdout)
    }

    private static func fetchExtensionRegistrationPaths() -> [String] {
        guard let result = try? runCLI(
            "pluginkit",
            arguments: ["-m", "-D", "-vv", "-i", "com.deanoc.spiderweb.fskit.app.extension"]
        ) else {
            return []
        }
        return result.stdout
            .split(separator: "\n")
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("Path = ") else { return nil }
                return String(trimmed.dropFirst("Path = ".count))
            }
    }

    private static func fetchActiveMountpoints() -> Set<String> {
        guard let result = try? runCLI("mount", arguments: []) else {
            return []
        }
        let lines = result.stdout.split(separator: "\n")
        var mountpoints: Set<String> = []
        for line in lines {
            let text = String(line)
            guard text.contains(" (spiderwebfs") || text.contains(" (spiderwebfs,") else { continue }
            guard let onRange = text.range(of: " on "), let parenRange = text.range(of: " (") else { continue }
            let mountpoint = String(text[onRange.upperBound..<parenRange.lowerBound])
            mountpoints.insert(mountpoint)
        }
        return mountpoints
    }

    private static func fetchLocalWorkspaces(using authStatus: SpiderwebAuthStatusSnapshot?) -> [SpiderwebWorkspaceSummary] {
        guard let adminToken = authStatus?.adminToken else { return [] }
        guard let result = try? runCLI(
            "spiderweb-control",
            arguments: ["--url", localServerURL, "--auth-token", adminToken, "workspace_list"]
        ) else {
            return []
        }
        guard let payload = try? extractControlPayloadObject(from: result.stdout),
              let workspaces = payload["workspaces"] as? [[String: Any]]
        else {
            return []
        }
        return workspaces.compactMap { item in
            guard let id = (item["workspace_id"] ?? item["project_id"]) as? String else { return nil }
            let name = item["name"] as? String ?? id
            let mountCount = (item["mount_count"] as? Int) ?? (item["mount_count"] as? NSNumber)?.intValue ?? 0
            return SpiderwebWorkspaceSummary(
                id: id,
                name: name,
                status: item["status"] as? String,
                kind: item["kind"] as? String,
                mountCount: mountCount
            )
        }
    }

    private static func decodeJSON<T: Decodable>(_ type: T.Type, from text: String) -> T? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func parseServiceStatusFromText(_ text: String) -> SpiderwebServiceStatusSnapshot? {
        let installed = text.contains("installed:  yes") || text.contains("installed: yes")
        let loaded = text.contains("loaded:     yes") || text.contains("loaded: yes")
        let unitPath = text
            .split(separator: "\n")
            .first { $0.contains("plist:") || $0.contains("unit:") }
            .map { line -> String in
                String(line.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "")
            } ?? ""
        let manager = text.contains("launchd") ? "launchd" : "systemd"
        return SpiderwebServiceStatusSnapshot(
            manager: manager,
            unitPath: unitPath,
            installed: installed,
            loaded: loaded,
            bind: nil,
            port: nil,
            remoteReachable: nil
        )
    }

    private static func fallbackServiceStatus() -> SpiderwebServiceStatusSnapshot? {
        let plistPath = "\(NSHomeDirectory())/Library/LaunchAgents/spiderweb.plist"
        guard FileManager.default.fileExists(atPath: plistPath) else { return nil }
        return SpiderwebServiceStatusSnapshot(
            manager: "launchd",
            unitPath: plistPath,
            installed: true,
            loaded: false,
            bind: "127.0.0.1",
            port: 18790,
            remoteReachable: false
        )
    }

    private static func deriveSavedMountsURL() -> URL {
        let base = appGroupContainerURL() ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Spiderweb", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent(savedMountsFilename)
    }

    private static func derivePairedNodeURL() -> URL {
        let base = appGroupContainerURL() ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Spiderweb", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent(pairedNodeFilename)
    }

    private static func remoteNodeSecretAccount(for nodeID: String) -> String {
        "remote_node_secret:\(nodeID)"
    }

    private static func loadSavedMounts() -> [SpiderwebSavedMount] {
        let url = deriveSavedMountsURL()
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([SpiderwebSavedMount].self, from: data)) ?? []
    }

    private static func persistSavedMounts(_ mounts: [SpiderwebSavedMount]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(mounts) else { return }
        try? data.write(to: deriveSavedMountsURL(), options: .atomic)
    }

    private static func loadPairedRemoteNode() -> SpiderwebPairedRemoteNode? {
        let url = derivePairedNodeURL()
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SpiderwebPairedRemoteNode.self, from: data)
    }

    private static func persistPairedRemoteNode(_ paired: SpiderwebPairedRemoteNode) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(paired) else { return }
        try? data.write(to: derivePairedNodeURL(), options: .atomic)
    }

    private static func deletePairedRemoteNode() {
        try? FileManager.default.removeItem(at: derivePairedNodeURL())
    }

    private static func fetchBuildInfo() -> SpiderwebBuildInfo {
        if let url = Bundle.main.url(forResource: "build-info", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(SpiderwebBuildInfo.self, from: data) {
            return decoded
        }

        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
            ?? "dev"
        return SpiderwebBuildInfo(
            version: version,
            gitCommit: nil,
            gitShortCommit: nil,
            gitDirty: nil,
            builtAtUTC: nil
        )
    }

    private static func discoverLocalHostnames() -> [String] {
        var candidates: [String] = []

        let processHostname = ProcessInfo.processInfo.hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !processHostname.isEmpty {
            candidates.append(processHostname)
        }

        let localized = (Host.current().localizedName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !localized.isEmpty {
            let sanitized = localized.replacingOccurrences(of: " ", with: "-")
            if sanitized.contains(".") {
                candidates.append(sanitized)
            } else {
                candidates.append("\(sanitized).local")
            }
        }

        var seen = Set<String>()
        return candidates.filter { candidate in
            let lowered = candidate.lowercased()
            guard !lowered.isEmpty, !seen.contains(lowered) else { return false }
            seen.insert(lowered)
            return true
        }
    }

    private static func discoverLocalIPv4Addresses() -> [String] {
        var results: [String] = []
        var seen = Set<String>()
        var ifaddrPointer: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddrPointer) == 0, let first = ifaddrPointer else {
            return []
        }
        defer { freeifaddrs(ifaddrPointer) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let address = interface.ifa_addr else { continue }
            guard address.pointee.sa_family == UInt8(AF_INET) else { continue }

            let flags = Int32(interface.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }

            let name = String(cString: interface.ifa_name)
            if name.hasPrefix("utun") || name.hasPrefix("awdl") || name.hasPrefix("llw") {
                continue
            }

            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(address.pointee.sa_len)
            let status = getnameinfo(address, length, &hostBuffer, socklen_t(hostBuffer.count), nil, 0, NI_NUMERICHOST)
            guard status == 0 else { continue }

            let host = String(cString: hostBuffer)
            guard !host.hasPrefix("169.254.") else { continue }
            guard seen.insert(host).inserted else { continue }
            results.append(host)
        }

        return results.sorted()
    }

    private static func shouldAutofillRemoteNodePublicBaseURL(current: String) -> Bool {
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let normalized = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return normalized == "ws://127.0.0.1:18790"
    }

    private static func preferredRemoteNodePublicBaseURL(from serviceStatus: SpiderwebServiceStatusSnapshot?) -> String? {
        let port = Int(serviceStatus?.port ?? 18790)
        if serviceStatus?.remoteReachable == false {
            return "ws://127.0.0.1:\(port)"
        }
        if let address = discoverLocalIPv4Addresses().first {
            return "ws://\(address):\(port)"
        }
        if let hostname = discoverLocalHostnames().first {
            return "ws://\(hostname):\(port)"
        }
        return "ws://127.0.0.1:\(port)"
    }

    private static func installFileSystemStatusMessage(
        nativeStatus: SpiderwebNativeStatusSnapshot?,
        extensionRegistrationPaths: [String]
    ) -> String {
        let hasDuplicates = extensionRegistrationPaths.contains { !$0.hasPrefix("/Applications/Spiderweb.app/") }
        guard let nativeStatus else {
            return "Installed Spiderweb file system support. Open System Settings -> General -> Login Items & Extensions -> File System Extensions and enable “Spiderweb file system”."
        }
        if nativeStatus.ready {
            return "Spiderweb file system is installed and ready."
        }
        if nativeStatus.registered && !nativeStatus.moduleEnabled {
            if hasDuplicates {
                return "Spiderweb file system is installed. Open System Settings -> General -> Login Items & Extensions -> File System Extensions, enable “Spiderweb file system” for /Applications/Spiderweb.app, and disable any older Spiderweb FSKit entry."
            }
            return "Spiderweb file system is installed. Open System Settings -> General -> Login Items & Extensions -> File System Extensions and enable “Spiderweb file system”."
        }
        return "Installed Spiderweb file system support. If macOS prompts for approval, enable “Spiderweb file system” in System Settings -> General -> Login Items & Extensions -> File System Extensions."
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

    private static func runCLI(
        _ command: String,
        arguments: [String],
        environment: [String: String] = [:],
        timeout: TimeInterval? = nil,
        timeoutBehavior: SpiderwebCommandTimeoutBehavior = .none
    ) throws -> SpiderwebCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: resolveExecutable(named: command))
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            finished.signal()
        }

        try process.run()

        if let timeout {
            let waitResult = finished.wait(timeout: .now() + timeout)
            if waitResult == .timedOut {
                if timeoutBehavior == .terminateProcessTree {
                    terminateProcessTree(rootPID: process.processIdentifier)
                } else {
                    if process.isRunning {
                        process.interrupt()
                        process.terminate()
                    }
                }
                throw SpiderwebAppError.message(
                    """
                    Native mount timed out after \(Int(timeout)) seconds.
                    On this Mac, rebooting often clears Apple's stuck FSKit mount state.
                    """
                )
            }
        } else {
            finished.wait()
        }

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        let result = SpiderwebCommandResult(
            status: process.terminationStatus,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self)
        )
        if result.status != 0 {
            throw SpiderwebAppError.commandFailed(command: command, stderr: result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        return result
    }

    private static func launchDetachedProcess(executableURL: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = nil
        process.standardOutput = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/null"))
        process.standardError = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/null"))
        try process.run()
    }

    private static func terminateProcessTree(rootPID: Int32) {
        let childPIDs = childProcessIDs(of: rootPID)
        for child in childPIDs {
            terminateProcessTree(rootPID: child)
        }

        _ = try? runCLI("/bin/kill", arguments: ["-TERM", String(rootPID)])
        usleep(200_000)
        _ = try? runCLI("/bin/kill", arguments: ["-KILL", String(rootPID)])
    }

    private static func childProcessIDs(of pid: Int32) -> [Int32] {
        guard let result = try? runCLI("/usr/bin/pgrep", arguments: ["-P", String(pid)]) else {
            return []
        }
        return result.stdout
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0) }
    }

    private static func resolveExecutable(named command: String) -> String {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/\(command)").path,
            "/usr/local/bin/\(command)",
            "/opt/homebrew/bin/\(command)",
            "/usr/bin/\(command)",
            "/bin/\(command)",
            command,
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return command
    }

    private static func extractControlPayloadObject(from text: String) throws -> [String: Any] {
        guard let data = text.data(using: .utf8) else {
            throw SpiderwebAppError.message("Control response was not valid UTF-8.")
        }
        let raw = try JSONSerialization.jsonObject(with: data)
        guard let envelope = raw as? [String: Any],
              let payload = envelope["payload"] as? [String: Any]
        else {
            throw SpiderwebAppError.message("Control response did not contain a payload object.")
        }
        return payload
    }

    private static func jsonString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    private static func derivedRemoteFsURL(from publicBaseURL: String) -> String {
        let trimmed = publicBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("/v2/fs") {
            return trimmed
        }
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v2/fs"
    }

    private static func storeSecret(service: String, account: String, value: String) throws {
        deleteSecret(service: service, account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SpiderwebAppError.message("Keychain write failed (\(status)).")
        }
    }

    private static func loadSecret(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func deleteSecret(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func deleteAllSecrets(service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func fetchLaunchAtLoginEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            switch SMAppService.mainApp.status {
            case .enabled, .requiresApproval:
                return true
            default:
                return false
            }
        }
        return false
    }

    private static func applyLaunchAtLogin(enabled: Bool) throws {
        guard #available(macOS 13.0, *) else { return }
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    private static func describe(error: Error) -> String {
        if let appError = error as? SpiderwebAppError {
            return enrichForKnownMacOSFailures(message: appError.localizedDescription)
        }
        return enrichForKnownMacOSFailures(message: error.localizedDescription)
    }

    private static func enrichForKnownMacOSFailures(message: String) -> String {
        let normalized = message.lowercased()

        let looksLikeExtensionKitLaunchFailure =
            normalized.contains("com.apple.extensionkit.errordomain error 2") ||
            normalized.contains("unable to invoke task") ||
            normalized.contains("failed with 69")
        let looksLikeResourceProbeFailure =
            normalized.contains("loading resource: filenotfound") ||
            normalized.contains("probing resource:")

        if looksLikeExtensionKitLaunchFailure || looksLikeResourceProbeFailure {
            return """
            \(message)

            This is a macOS FSKit/ExtensionKit launch failure, not a Spiderweb auth or workspace error.
            If you just reinstalled or upgraded Spiderweb, quit Spiderweb.app and reboot this Mac once, then try the mount again.
            """
        }

        return message
    }

    private static func bestEffortUnmount(_ mountpoint: String) {
        if (try? runCLI("diskutil", arguments: ["unmount", "force", mountpoint])) != nil {
            return
        }
        _ = try? runCLI("umount", arguments: [mountpoint])
    }

    private static func writeSelfUninstallScript() throws -> URL {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let scriptURL = tempDirectory.appendingPathComponent("spiderweb-uninstall-\(UUID().uuidString).sh")

        let home = NSHomeDirectory()
        let appPath = Bundle.main.bundlePath
        let userCleanupCommands = [
            "/bin/rm -rf \(shellQuoted("\(home)/Library/Application Support/Spiderweb"))",
            "/bin/rm -rf \(shellQuoted("\(home)/Library/Group Containers/\(appGroupIdentifier)"))",
            "/bin/rm -rf \(shellQuoted("\(home)/Library/Saved Application State/com.deanoc.spiderweb.fskit.app.savedState"))",
            "/bin/rm -f \(shellQuoted("\(home)/Library/Preferences/com.deanoc.spiderweb.fskit.app.plist"))",
            "/bin/rm -f \(shellQuoted("\(home)/Library/LaunchAgents/spiderweb.plist"))",
            "/bin/rm -f \(shellQuoted("\(home)/.config/spiderweb/config.json"))",
            "/bin/rm -rf \(shellQuoted("\(home)/Applications/SpiderwebFSKit.app"))",
        ].joined(separator: "\n")

        let privilegedCommand = [
            "/bin/rm -rf \(shellQuoted(appPath))",
            "/bin/rm -rf /Applications/SpiderwebFSKit.app",
            "/bin/rm -rf /Library/Filesystems/spiderweb.fs",
            "/bin/rm -rf /Library/Filesystems/passthrough.fs",
            "/bin/rm -f /usr/local/bin/spiderweb",
            "/bin/rm -f /usr/local/bin/spiderweb-config",
            "/bin/rm -f /usr/local/bin/spiderweb-control",
            "/bin/rm -f /usr/local/bin/spiderweb-fs-mount",
            "/bin/rm -f /usr/local/bin/spiderweb-fs-node",
            "/bin/rm -f /usr/local/bin/spiderweb-local-node",
            "/bin/rm -f /usr/local/bin/spiderweb-local-service",
            "/usr/sbin/pkgutil --forget com.deanoc.spiderweb.filesystems.fs.spiderweb.pkg >/dev/null 2>&1 || true",
        ].joined(separator: "; ")

        let appleScript = "do shell script \(appleScriptStringLiteral(privilegedCommand)) with administrator privileges"
        let script = """
        #!/bin/sh
        set -eu
        sleep 2
        \(userCleanupCommands)
        /usr/bin/osascript -e \(shellQuoted(appleScript)) >/dev/null 2>&1 || true
        /bin/rm -f "$0"
        """

        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func appleScriptStringLiteral(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

enum SpiderwebAppError: LocalizedError {
    case message(String)
    case commandFailed(command: String, stderr: String)

    var errorDescription: String? {
        switch self {
        case .message(let message):
            return message
        case .commandFailed(let command, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "\(command) failed." : trimmed
        }
    }
}
