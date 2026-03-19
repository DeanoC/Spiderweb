import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var controller: SpiderwebAppController
    @State private var revealLocalTokens = false
    @State private var newWorkspaceName = ""
    @State private var newWorkspaceVision = ""

    var body: some View {
        NavigationSplitView {
            List(selection: $controller.selectedSection) {
                ForEach(SpiderwebAppSection.allCases) { section in
                    Label(section.title, systemImage: section.symbolName)
                        .tag(section)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    statusBanner
                    detailContent
                }
                .padding(24)
            }
            .frame(minWidth: 900, minHeight: 720)
        }
        .alert("Uninstall Spiderweb?", isPresented: $controller.showingUninstallAlert) {
            Button("Uninstall", role: .destructive) {
                controller.uninstallSpiderweb()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes Spiderweb.app, the background service, native file system support, saved mounts, local Spiderweb data, and Spiderweb secrets from this Mac. Spiderweb will quit when uninstall begins.")
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Spiderweb")
                    .font(.system(size: 30, weight: .semibold))
                Text("Native mounts, saved workspaces, and remote-node setup for macOS.")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 10) {
                Button("Open System Settings") {
                    controller.openSystemSettings()
                }
                .buttonStyle(.bordered)

                Button("Refresh") {
                    controller.refresh()
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        if let error = controller.lastError {
            InlineBanner(text: error, tint: .red)
        } else if let status = controller.statusMessage {
            InlineBanner(text: status, tint: .blue)
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch controller.selectedSection {
        case .overview:
            overviewView
        case .mounts:
            mountsView
        case .thisMac:
            thisMacView
        case .settings:
            settingsView
        }
    }

    private var overviewView: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Overview")
                .font(.title2.weight(.semibold))

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                StatusCard(
                    title: "Background Service",
                    value: controller.serviceStatus?.loaded == true ? "Running" : (controller.serviceStatus?.installed == true ? "Installed" : "Not installed"),
                    detail: controller.serviceStatus?.unitPath ?? "Spiderweb is not registered to launch in the background yet."
                )
                StatusCard(
                    title: "Spiderweb File System",
                    value: controller.nativeStatusHeadline,
                    detail: controller.nativeStatusDetailText
                )
                StatusCard(
                    title: "Saved Mounts",
                    value: "\(controller.savedMounts.count)",
                    detail: controller.mountedSavedMounts.isEmpty ? "No active native mounts right now." : "\(controller.mountedSavedMounts.count) mounted right now."
                )
                StatusCard(
                    title: "Remote Node",
                    value: controller.pairedRemoteNode == nil ? "Not paired" : (controller.remoteNodeStatus?.secretPresent == true ? "Paired" : "Needs attention"),
                    detail: controller.pairedRemoteNode?.remoteControlURL ?? "This Mac is not currently paired to a remote Spiderweb."
                )
            }

            setupChecklistPanel
            setupChoices
            quickMountsPanel
        }
    }

    private var setupChecklistPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Setup Checklist")
                .font(.headline)

            ChecklistRow(
                title: "Local background service",
                detail: controller.serviceStatus?.loaded == true
                    ? "Spiderweb is already running in the background for this user."
                    : "Install / Start Service creates a per-user background service so local workspaces, agents, and remote-node mode can run without Terminal.",
                isComplete: controller.serviceStatus?.loaded == true,
                actionTitle: controller.serviceStatus?.loaded == true ? nil : "Install / Start Service",
                action: controller.serviceStatus?.loaded == true ? nil : { controller.installLocalService() }
            )

            ChecklistRow(
                title: "Spiderweb file system support",
                detail: controller.nativeStatus?.registered == true
                    ? "Spiderweb file system support is installed. If you just changed anything in System Settings, click Refresh here."
                    : "Install File System may ask for admin approval. It installs the native Spiderweb file system support that Finder and editors use.",
                isComplete: controller.nativeStatus?.registered == true,
                actionTitle: controller.nativeStatus?.registered == true ? nil : "Install File System",
                action: controller.nativeStatus?.registered == true ? nil : { controller.installFileSystem() }
            )

            ChecklistRow(
                title: "Enable “Spiderweb file system” in System Settings",
                detail: controller.nativeStatus?.moduleEnabled == true
                    ? "macOS currently reports the Spiderweb file system as enabled."
                    : "After install, open System Settings -> General -> Login Items & Extensions -> File System Extensions, turn on “Spiderweb file system”, then return here and click Refresh.",
                isComplete: controller.nativeStatus?.moduleEnabled == true,
                actionTitle: controller.nativeStatus?.moduleEnabled == true ? nil : "Open System Settings",
                action: controller.nativeStatus?.moduleEnabled == true ? nil : { controller.openSystemSettings() }
            )

            ChecklistRow(
                title: "Mount local or remote workspaces",
                detail: controller.nativeStatus?.ready == true
                    ? "Native mounts are ready. You can save mounts in the Mounts section or create a local mount from This Mac."
                    : "Mounts become available once the file system is installed and enabled.",
                isComplete: controller.nativeStatus?.ready == true,
                actionTitle: "Refresh",
                action: { controller.refresh() }
            )
        }
        .padding(18)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var setupChoices: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose a Path")
                .font(.headline)

            ForEach(SpiderwebOnboardingPath.allCases) { path in
                Button {
                    controller.highlightedOnboardingPath = path
                    switch path {
                    case .localHost: controller.selectedSection = .thisMac
                    case .remoteMount:
                        controller.beginNewMount(kind: .remote)
                        controller.selectedSection = .mounts
                    case .remoteNode:
                        controller.selectedSection = .thisMac
                    }
                } label: {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: path.symbolName)
                            .font(.title2)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(path.title)
                                .font(.headline)
                            Text(path.subtitle)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(16)
                    .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(path == controller.highlightedOnboardingPath ? Color.accentColor : Color.secondary.opacity(0.15), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var quickMountsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Quick Mounts")
                .font(.headline)

            if controller.savedMounts.isEmpty {
                Text("No saved mounts yet. Add one in the Mounts section.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(controller.savedMounts) { mount in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(mount.name)
                                .font(.headline)
                            Text("\(mount.serverURL) • \(mount.mountpoint)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if controller.activeMountpoints.contains(mount.mountpoint) {
                            Button("Reveal") {
                                controller.reveal(mount: mount)
                            }
                            Button("Unmount") {
                                controller.unmount(mount)
                            }
                        } else {
                            Button("Mount") {
                                controller.mount(mount)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(18)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var mountsView: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Mounts")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("New Local Mount") {
                    controller.beginNewMount(kind: .local)
                }
                Button("New Remote Mount") {
                    controller.beginNewMount(kind: .remote)
                }
            }

            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Saved Mounts")
                        .font(.headline)

                    if controller.savedMounts.isEmpty {
                        Text("Save local or remote mounts here so they’re easy to mount again from the menu bar.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(controller.savedMounts) { mount in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(mount.name)
                                            .font(.headline)
                                        Text("\(mount.kind.rawValue.capitalized) • \(mount.workspaceID) • \(mount.mountpoint)")
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(controller.activeMountpoints.contains(mount.mountpoint) ? "Mounted" : "Idle")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(controller.activeMountpoints.contains(mount.mountpoint) ? .green : .secondary)
                                }

                                HStack(spacing: 10) {
                                    Button("Edit") {
                                        controller.editMount(mount)
                                    }
                                    Button("Copy CLI") {
                                        controller.copyMountCommand(for: mount)
                                    }
                                    if controller.activeMountpoints.contains(mount.mountpoint) {
                                        Button("Reveal") {
                                            controller.reveal(mount: mount)
                                        }
                                        Button("Unmount") {
                                            controller.unmount(mount)
                                        }
                                    } else {
                                        Button("Mount") {
                                            controller.mount(mount)
                                        }
                                    }
                                    Button("Delete", role: .destructive) {
                                        controller.deleteMount(mount)
                                    }
                                }
                                .buttonStyle(.bordered)
                            }
                            .padding(14)
                            .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                mountEditorPanel
                    .frame(maxWidth: 360)
            }
        }
    }

    private var mountEditorPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(controller.mountEditor.editingID == nil ? "New Mount" : "Edit Mount")
                .font(.headline)

            Picker("Mount kind", selection: $controller.mountEditor.kind) {
                Text("Local").tag(SpiderwebSavedMountKind.local)
                Text("Remote").tag(SpiderwebSavedMountKind.remote)
            }
            .pickerStyle(.segmented)

            TextField("Name", text: $controller.mountEditor.name)

            if controller.mountEditor.kind == .remote {
                TextField("Server URL", text: $controller.mountEditor.serverURL)
            } else {
                TextField("Server URL", text: .constant(SpiderwebAppController.localServerURL))
                    .disabled(true)
            }

            TextField("Workspace ID", text: $controller.mountEditor.workspaceID)
            TextField("Mountpoint", text: $controller.mountEditor.mountpoint)

            if controller.mountEditor.kind == .remote {
                SecureField("Auth Token", text: $controller.mountEditor.authToken)
            } else {
                Text("Local mounts use the local Spiderweb runtime token automatically.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Save Mount") {
                    controller.saveMountDraft()
                }
                Button("Reset") {
                    controller.mountEditor.reset(homeDirectory: NSHomeDirectory())
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(18)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var thisMacView: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("This Mac")
                .font(.title2.weight(.semibold))

            localSpiderwebPanel
            remoteNodePanel
        }
    }

    private var localSpiderwebPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Local Spiderweb")
                .font(.headline)

            Text("Run Spiderweb in the background on this Mac, manage local workspaces, and create saved local mounts.")
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button("Install / Start Service") {
                    controller.installLocalService()
                }
                Button("Install File System") {
                    controller.installFileSystem()
                }
                Button("Open System Settings") {
                    controller.openSystemSettings()
                }
                .buttonStyle(.bordered)
                Button("Refresh Workspaces") {
                    controller.refreshWorkspaces()
                }
                Button("Uninstall Service", role: .destructive) {
                    controller.uninstallLocalService()
                }
            }

            Text("Install / Start Service sets up Spiderweb for this user. Install File System may ask for admin approval, and macOS still requires one manual enable step in System Settings before native mounts become ready.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            localAccessPanel
            localWorkspaceCreationPanel

            if controller.nativeStatus?.ready != true {
                VStack(alignment: .leading, spacing: 10) {
                    Text("File System Enablement")
                        .font(.headline)
                    Text(controller.nativeStatusDetailText)
                        .foregroundStyle(.secondary)
                    ForEach(Array(controller.nativeEnablementSteps.enumerated()), id: \.offset) { index, step in
                        Text("\(index + 1). \(step)")
                            .font(.footnote)
                    }
                }
                .padding(14)
                .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            if controller.mountableLocalWorkspaces.isEmpty {
                Text("No local workspaces loaded yet. Create one below, then save a local mount from it.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Local Workspaces")
                    .font(.headline)
                ForEach(controller.mountableLocalWorkspaces) { workspace in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(workspace.name)
                                .font(.headline)
                            Text("\(workspace.id) • \(workspace.status ?? "unknown") • \(workspace.mountCount) mount\(workspace.mountCount == 1 ? "" : "s")")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        HStack(spacing: 8) {
                            Button("Create Saved Mount") {
                                controller.createSavedLocalMount(for: workspace)
                            }
                            Button("Delete Workspace", role: .destructive) {
                                controller.deleteWorkspace(workspace)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            if !controller.nonMountableLocalWorkspaces.isEmpty {
                Text("Not Mountable Yet")
                    .font(.headline)
                ForEach(controller.nonMountableLocalWorkspaces) { workspace in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(workspace.name)
                            .font(.headline)
                        Text("\(workspace.id) • \(workspace.status ?? "unknown") • 0 mounts")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text("This usually means the local Spiderweb filesystem node is not ready yet. Reinstall or restart the local service, then refresh workspaces.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Delete Workspace", role: .destructive) {
                            controller.deleteWorkspace(workspace)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(18)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var localWorkspaceCreationPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create Workspace")
                .font(.headline)

            Text("Local mounts need a real Spiderweb workspace. Create one here, then save a local mount from the workspace list below.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            TextField("Workspace name", text: $newWorkspaceName)
            TextField("Workspace vision", text: $newWorkspaceVision, axis: .vertical)
                .lineLimit(3...5)

            HStack {
                Button("Create Workspace") {
                    let name = newWorkspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let vision = newWorkspaceVision.trimmingCharacters(in: .whitespacesAndNewlines)
                    controller.createWorkspace(
                        name: name.isEmpty ? "New Workspace" : name,
                        vision: vision.isEmpty ? "Created from Spiderweb.app on macOS." : vision
                    )
                    newWorkspaceName = ""
                    newWorkspaceVision = ""
                }
                .disabled(controller.serviceStatus?.loaded != true)

                if controller.serviceStatus?.loaded != true {
                    Text("Start the local service first.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private var localAccessPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Local Access Tokens")
                    .font(.headline)
                Spacer()
                Button(revealLocalTokens ? "Hide" : "Reveal") {
                    revealLocalTokens.toggle()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if let auth = controller.authStatus {
                Text("Use these tokens when another Mac, a remote tool, or a saved remote mount needs to connect back to the Spiderweb service running on this Mac.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Connection URLs")
                        .font(.subheadline.weight(.semibold))
                    if controller.serviceStatus?.remoteReachable == false {
                        Text("Spiderweb is currently bound to \(controller.serviceStatus?.bind ?? "127.0.0.1"), so only this Mac can connect. Install / Start Service again or enable remote-node setup to switch to a LAN-reachable bind.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Use the local-only URL on this Mac. For another machine, copy one of the network URLs below.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(controller.localAccessEndpoints) { endpoint in
                        SecretValueRow(
                            title: endpoint.title,
                            detail: endpoint.detail,
                            value: endpoint.url,
                            copyLabel: "Copy URL",
                            copyAction: {
                                controller.copyToClipboard(endpoint.url)
                            }
                        )
                    }
                }

                SecretValueRow(
                    title: "Access token",
                    detail: "Use this token when another Mac, tool, or saved remote mount needs to connect to this Spiderweb service.",
                    value: revealLocalTokens ? (auth.adminToken ?? "") : maskedToken(auth.adminToken),
                    copyLabel: "Copy Access Token",
                    copyAction: {
                        if let token = auth.adminToken {
                            controller.copyToClipboard(token)
                        }
                    }
                )

                SecretValueRow(
                    title: "Token file",
                    detail: "Where Spiderweb stores the local auth tokens on this Mac.",
                    value: auth.path,
                    copyLabel: "Copy Path",
                    copyAction: {
                        controller.copyToClipboard(auth.path)
                    }
                )
            } else {
                Text("Local auth tokens are not available yet. Install / Start Service first, then click Refresh.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var remoteNodePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Remote Node")
                .font(.headline)

            Text("Pair this Mac to a remote Spiderweb with an invite token and expose its filesystem as a remote node.")
                .foregroundStyle(.secondary)

            if let paired = controller.pairedRemoteNode {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Currently paired as \(paired.nodeName)")
                        .font(.headline)
                    Text("\(paired.remoteControlURL) • \(paired.exportPath)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Disconnect") {
                            controller.unpairRemoteNode()
                        }
                        Button("Forget Locally", role: .destructive) {
                            controller.clearRemoteNodePairing()
                        }
                    }
                }
                .padding(14)
                .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            TextField("Remote control URL", text: $controller.remoteNodeDraft.remoteControlURL)
            SecureField("Invite token", text: $controller.remoteNodeDraft.inviteToken)
            TextField("Node name", text: $controller.remoteNodeDraft.nodeName)
            TextField("Reachable public base URL", text: $controller.remoteNodeDraft.publicBaseURL)
            TextField("Export path", text: $controller.remoteNodeDraft.exportPath)
            TextField("Export name", text: $controller.remoteNodeDraft.exportName)
            Toggle("Read-only export", isOn: $controller.remoteNodeDraft.exportRO)

            HStack {
                Button("Pair This Mac") {
                    controller.pairRemoteNode()
                }
                .disabled(controller.pairedRemoteNode != nil)
                Button("Open Settings") {
                    controller.openSystemSettings()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(18)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var settingsView: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Settings")
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 10) {
                Toggle(
                    "Launch Spiderweb at login",
                    isOn: Binding(
                        get: { controller.launchAtLoginEnabled },
                        set: { controller.setLaunchAtLoginEnabled($0) }
                    )
                )
                Text("Keeps the menu bar app available after sign-in so saved mounts and local-host status stay close at hand.")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }
            .padding(18)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            SettingsRow(
                title: "Diagnostics",
                detail: "Native FS status is shared through the Spiderweb app group container so the app and extension can stay in sync."
            )
            VStack(alignment: .leading, spacing: 10) {
                Text("Build Diagnostics")
                    .font(.headline)
                Text(controller.diagnosticsSummary)
                    .textSelection(.enabled)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Copy Diagnostics") {
                    controller.copyDiagnostics()
                }
                .buttonStyle(.bordered)
            }
            .padding(18)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            SettingsRow(
                title: "Known limitations",
                detail: "Owner/group changes and hard links remain unsupported on the native macOS mount. Out-of-band edits on already-seen host files can remain stale until reopen or remount."
            )
            VStack(alignment: .leading, spacing: 10) {
                Text("Uninstall")
                    .font(.headline)
                Text("Remove Spiderweb.app, the background service, native file system support, saved mounts, local Spiderweb data, and Spiderweb secrets from this Mac. Spiderweb will quit after you confirm.")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
                Button("Uninstall Spiderweb…", role: .destructive) {
                    controller.showingUninstallAlert = true
                }
                .buttonStyle(.bordered)
            }
            .padding(18)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}

private func maskedToken(_ value: String?) -> String {
    guard let value, !value.isEmpty else { return "(unavailable)" }
    guard value.count > 8 else { return "****" }
    return "\(value.prefix(4))...\(value.suffix(4))"
}

private struct InlineBanner: View {
    let text: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                copyToPasteboard(text)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .foregroundStyle(tint)
    }

    private func copyToPasteboard(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }
}

private struct StatusCard: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(value)
                .font(.title3.weight(.semibold))
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct SettingsRow: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            Text(detail)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct ChecklistRow: View {
    let title: String
    let detail: String
    let isComplete: Bool
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isComplete ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isComplete ? .green : .secondary)
                .font(.title3)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(isComplete ? "Done" : "Needed")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isComplete ? .green : .secondary)
                }
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct SecretValueRow: View {
    let title: String
    let detail: String
    let value: String
    let copyLabel: String
    let copyAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 10) {
                Text(value)
                    .textSelection(.enabled)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(copyLabel, action: copyAction)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

#Preview {
    ContentView()
        .environmentObject(SpiderwebAppController())
}
