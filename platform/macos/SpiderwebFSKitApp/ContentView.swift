import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var controller: SpiderwebAppController
    @State private var revealLocalTokens = false
    @State private var newWorkspaceName = ""
    @State private var newWorkspaceVision = ""
    @State private var activeRecipe: SpiderwebRecipe?

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
        .sheet(item: $activeRecipe) { recipe in
            SpiderwebRecipeSheet(
                recipe: recipe,
                primaryAction: {
                    runRecipePrimaryAction(recipe)
                },
                secondaryAction: recipe.secondaryButtonTitle == nil ? nil : {
                    runRecipeSecondaryAction(recipe)
                }
            )
            .environmentObject(controller)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Spiderweb")
                    .font(.system(size: 30, weight: .semibold))
                Text("Start a workspace, connect devices, and manage Spiderweb drives on macOS.")
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
            VStack(alignment: .leading, spacing: 6) {
                Text("Get Started")
                    .font(.title2.weight(.semibold))
                Text("Lead with one local workspace. Once the drive is working, come back for devices, packages, and remote flows.")
                    .foregroundStyle(.secondary)
            }

            quickstartHeroPanel
            overviewRecipesPanel
            secondaryPathsPanel
            quickstartNextStepsPanel
            setupChecklistPanel
            quickMountsPanel
        }
    }

    private var overviewRecipesPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Useful Next Paths")
                .font(.headline)

            Text("Spider is most approachable when each step has a job: start local, connect another machine, mount something remote, or contribute this Mac elsewhere.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                OnboardingRecipeCard(
                    eyebrow: "Remote Access",
                    title: "Mount an Existing Spiderweb",
                    summary: "Use this when a Spiderweb is already running somewhere else and you just want its workspace as a drive on this Mac.",
                    steps: [
                        "Copy the remote Spiderweb URL and access token.",
                        "Pick the workspace id and local mount path.",
                        "Save the drive, then mount it from the Mounts screen."
                    ],
                    progress: SpiderwebRecipe.mountExistingSpiderweb.progress(using: controller),
                    buttonTitle: "Open Remote Drive Setup",
                    action: {
                        activeRecipe = .mountExistingSpiderweb
                    }
                )
                OnboardingRecipeCard(
                    eyebrow: "Connect Devices",
                    title: "Let Another Mac Connect to This Spiderweb",
                    summary: "Run Spiderweb on this Mac, then share a network URL and access token so another Mac or tool can connect back here.",
                    steps: [
                        "Install / Start Service on this Mac.",
                        "Reveal the local access tokens and copy a network URL.",
                        "Use that URL and token from another Mac, SpiderApp, or a saved remote drive."
                    ],
                    progress: SpiderwebRecipe.shareThisSpiderweb.progress(using: controller),
                    buttonTitle: "Open Local Access",
                    action: {
                        activeRecipe = .shareThisSpiderweb
                    }
                )
                OnboardingRecipeCard(
                    eyebrow: "Contribute This Mac",
                    title: "Provide This Mac to a Remote Spiderweb",
                    summary: "Use an invite token to pair this Mac as a remote device so another Spiderweb can use its files or services.",
                    steps: [
                        "Paste the remote control URL and invite token.",
                        "Choose what path this Mac should export.",
                        "Pair the Mac, then confirm it shows up in the remote workspace topology."
                    ],
                    progress: SpiderwebRecipe.provideThisMac.progress(using: controller),
                    buttonTitle: "Open Pairing Setup",
                    action: {
                        activeRecipe = .provideThisMac
                    }
                )
            }
        }
        .padding(18)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var quickstartHeroPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Start Here")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("Start Local Workspace")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("Spiderweb will install what it needs, create a workspace, mount a drive under your home folder, and open the result in Finder.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(controller.quickstartStepTitle)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(NSColor.textBackgroundColor), in: Capsule())
                    .foregroundStyle(controller.quickstartState?.isComplete == true ? .green : .secondary)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                HeroFactCard(
                    title: "Default Path",
                    value: "Just Try It",
                    detail: "The fastest way to see Spiderweb as a drive on this Mac."
                )
                HeroFactCard(
                    title: "Drive Location",
                    value: controller.quickstartDrivePath ?? "~/Spiderweb/<workspace-name>",
                    detail: "A deterministic path you can open in Finder, editors, and tools."
                )
                HeroFactCard(
                    title: "What You Get",
                    value: "Workspace + Drive",
                    detail: "A ready local workspace first, then SpiderApp for devices and packages."
                )
            }

            if let drivePath = controller.quickstartDrivePath {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Drive Path")
                        .font(.subheadline.weight(.semibold))
                    Text(drivePath)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
                .padding(12)
                .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            Text(controller.quickstartDetail)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                if controller.quickstartState?.isComplete == true {
                    if controller.quickstartCanOpenSpiderApp {
                        Button(controller.quickstartPrimaryButtonTitle) {
                            controller.openSpiderApp()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    if controller.quickstartState?.result?.driveIssueSummary?.isEmpty == false {
                        Button("Retry Drive Mount") {
                            controller.startLocalWorkspaceQuickstart()
                        }
                        .buttonStyle(.bordered)
                    }
                } else {
                    Button(controller.quickstartPrimaryButtonTitle) {
                        controller.startLocalWorkspaceQuickstart()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.isBusy)
                }

                if controller.quickstartNeedsSystemApproval {
                    Button("Open System Settings") {
                        controller.openSystemSettings()
                    }
                    .buttonStyle(.bordered)
                }

                if controller.quickstartCanRevealDrive {
                    Button("Reveal Drive") {
                        controller.revealQuickstartDrive()
                    }
                    .buttonStyle(.bordered)
                }
            }

            Text("Prefer a different first step? Use the paths below to mount an existing Spiderweb or connect this Mac to another workspace.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .background(
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.18),
                    Color(NSColor.controlBackgroundColor)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.accentColor.opacity(0.16), lineWidth: 1)
        )
    }

    private var setupChecklistPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Need Help or Manual Setup?")
                .font(.headline)

            Text("These details matter when you need approvals, want to troubleshoot the local runtime, or prefer a more manual path.")
                .foregroundStyle(.secondary)

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
                    title: "Saved Drives",
                    value: "\(controller.savedMounts.count)",
                    detail: controller.mountedSavedMounts.isEmpty ? "No active native drives right now." : "\(controller.mountedSavedMounts.count) mounted right now."
                )
                StatusCard(
                    title: "Remote Node",
                    value: controller.pairedRemoteNode == nil ? "Not paired" : (controller.remoteNodeStatus?.secretPresent == true ? "Paired" : "Needs attention"),
                    detail: controller.pairedRemoteNode?.remoteControlURL ?? "This Mac is not currently paired to a remote Spiderweb."
                )
            }

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
                title: "Mount local or remote drives",
                detail: controller.nativeStatus?.ready == true
                    ? "Native drives are ready. You can save drives in the Mounts section or create a local drive from This Mac."
                    : "Drives become available once the file system is installed and enabled.",
                isComplete: controller.nativeStatus?.ready == true,
                actionTitle: "Refresh",
                action: { controller.refresh() }
            )
        }
        .padding(18)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var secondaryPathsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Other Ways to Start")
                .font(.headline)

            Text("Use these when your first goal is remote access or contributing this Mac to another Spiderweb instead of starting locally.")
                .foregroundStyle(.secondary)

            ForEach([SpiderwebOnboardingPath.remoteMount, SpiderwebOnboardingPath.remoteNode]) { path in
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

    private var quickstartNextStepsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Keep Going")
                .font(.headline)

            if controller.quickstartState?.isComplete != true {
                Text("Finish the local workspace first. After that, use SpiderApp for devices, packages, recipes, and the richer workspace shell.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    if controller.quickstartCanOpenSpiderApp {
                        actionCard(
                            title: "Open SpiderApp",
                            detail: controller.quickstartNextStepDetail,
                            buttonTitle: "Open SpiderApp",
                            action: {
                                controller.openSpiderApp()
                            }
                        )
                    } else {
                        actionCard(
                            title: "Use the Mounted Drive",
                            detail: controller.quickstartNextStepDetail,
                            buttonTitle: "Reveal Drive",
                            action: {
                                controller.revealQuickstartDrive()
                            }
                        )
                    }
                    actionCard(
                        title: "Connect Machines",
                        detail: "Bring in another machine, or contribute this Mac to a remote Spiderweb, once you have seen the first drive working.",
                        buttonTitle: "Open Guide",
                        action: {
                            activeRecipe = .provideThisMac
                        }
                    )
                    actionCard(
                        title: "Add Packages and Services",
                        detail: "Packages are Spider's installable capabilities. Older internal docs may call them venoms, but the user-facing flow should stay package-first.",
                        buttonTitle: "Open Guide",
                        action: {
                            activeRecipe = .packagesAndServices
                        }
                    )
                    actionCard(
                        title: "Create More Drives",
                        detail: "Use Mounts for additional local or remote drives once the first workspace path makes sense.",
                        buttonTitle: "Open Drives",
                        action: {
                            controller.selectedSection = .mounts
                        }
                    )
                }
            }
        }
        .padding(18)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var quickMountsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Saved Drives")
                .font(.headline)

            if controller.savedMounts.isEmpty {
                Text("No saved drives yet. Add one in the Mounts section.")
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
                Text("Drives")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("New Local Drive") {
                    controller.beginNewMount(kind: .local)
                }
                Button("New Remote Drive") {
                    controller.beginNewMount(kind: .remote)
                }
            }

            OnboardingRecipeCard(
                eyebrow: "Recipe",
                title: "Mount a Remote Workspace",
                summary: "When another Spiderweb is already running, create a saved remote drive here so Finder, editors, and tools can use it like a local path.",
                steps: [
                    "Paste the remote Spiderweb URL and access token.",
                    "Set the workspace id and a mount path under ~/Spiderweb.",
                    "Save the drive, then mount or reveal it from this screen."
                ],
                progress: SpiderwebRecipe.mountExistingSpiderweb.progress(using: controller),
                buttonTitle: "New Remote Drive",
                action: {
                    activeRecipe = .mountExistingSpiderweb
                }
            )

            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Saved Drives")
                        .font(.headline)

                    if controller.savedMounts.isEmpty {
                        Text("Save local or remote drives here so they’re easy to mount again from the menu bar.")
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
            Text(controller.mountEditor.editingID == nil ? "New Drive" : "Edit Drive")
                .font(.headline)

            Picker("Drive kind", selection: $controller.mountEditor.kind) {
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
                Text("Local drives use the local Spiderweb runtime token automatically.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Save Drive") {
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

            thisMacRecipesPanel
            localSpiderwebPanel
            remoteNodePanel
        }
    }

    private var thisMacRecipesPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Useful Configurations")
                .font(.headline)

            Text("This is where Spiderweb shifts from one local drive into a distributed workspace: sharing access, pairing this Mac remotely, or creating additional local workspaces.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                OnboardingRecipeCard(
                    eyebrow: "Share This Host",
                    title: "Connect Another Mac to This Spiderweb",
                    summary: "Expose this Mac as the Spiderweb host another machine connects to.",
                    steps: [
                        "Start the local service here.",
                        "Copy a network URL and access token from Local Access Tokens.",
                        "Use those on the other machine to connect and choose a workspace."
                    ],
                    progress: SpiderwebRecipe.shareThisSpiderweb.progress(using: controller),
                    buttonTitle: "Reveal Access Tokens",
                    action: {
                        activeRecipe = .shareThisSpiderweb
                    }
                )
                OnboardingRecipeCard(
                    eyebrow: "Create Workspace",
                    title: "Set Up a Useful Local Workspace",
                    summary: "A workspace is the shared root that drives, packages, and tools attach to. Start with one clear purpose, then expand it.",
                    steps: [
                        "Give the workspace a recognizable name.",
                        "Describe the goal in one sentence so later devices and tools make sense.",
                        "Create a saved drive from that workspace once it appears below."
                    ],
                    progress: SpiderwebRecipe.setupUsefulWorkspace.progress(using: controller),
                    buttonTitle: "Open Workspace Guide",
                    action: {
                        activeRecipe = .setupUsefulWorkspace
                    }
                )
                OnboardingRecipeCard(
                    eyebrow: "Remote Pairing",
                    title: "Provide This Mac to Another Spiderweb",
                    summary: "Pair this Mac as a remote device so another Spiderweb can mount its exported path or use its services.",
                    steps: [
                        "Paste the remote control URL and invite token.",
                        "Choose the export path and whether it should be read-only.",
                        "Pair this Mac and verify it appears in the remote Spiderweb."
                    ],
                    progress: SpiderwebRecipe.provideThisMac.progress(using: controller),
                    buttonTitle: "Open Pairing Guide",
                    action: {
                        activeRecipe = .provideThisMac
                    }
                )
            }
        }
        .padding(18)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func runRecipePrimaryAction(_ recipe: SpiderwebRecipe) {
        activeRecipe = nil
        switch recipe {
        case .mountExistingSpiderweb:
            controller.highlightedOnboardingPath = .remoteMount
            controller.beginNewMount(kind: .remote)
            controller.selectedSection = .mounts
        case .shareThisSpiderweb:
            revealLocalTokens = true
            controller.selectedSection = .thisMac
        case .provideThisMac:
            controller.highlightedOnboardingPath = .remoteNode
            controller.selectedSection = .thisMac
        case .setupUsefulWorkspace:
            controller.selectedSection = .thisMac
        case .packagesAndServices:
            if controller.quickstartCanOpenSpiderApp {
                controller.openSpiderApp()
            } else if controller.quickstartCanRevealDrive {
                controller.revealQuickstartDrive()
            } else {
                controller.selectedSection = .overview
            }
        }
    }

    private func runRecipeSecondaryAction(_ recipe: SpiderwebRecipe) {
        activeRecipe = nil
        switch recipe {
        case .mountExistingSpiderweb:
            revealLocalTokens = true
            controller.selectedSection = .thisMac
        case .shareThisSpiderweb:
            controller.beginNewMount(kind: .remote)
            controller.selectedSection = .mounts
        case .provideThisMac:
            controller.openSystemSettings()
        case .setupUsefulWorkspace:
            controller.selectedSection = .overview
            controller.startLocalWorkspaceQuickstart()
        case .packagesAndServices:
            controller.selectedSection = .overview
        }
    }

    private var localSpiderwebPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Local Spiderweb")
                .font(.headline)

            Text("Run Spiderweb in the background on this Mac, manage local workspaces, and create saved local drives.")
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

            Text("Install / Start Service sets up Spiderweb for this user. Install File System may ask for admin approval, and macOS still requires one manual enable step in System Settings before native drives become ready.")
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
                Text("No local workspaces loaded yet. Create one below, then save a local drive from it.")
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
                            Button("Create Saved Drive") {
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
            Text("Create a Useful Workspace")
                .font(.headline)

            Text("Local drives need a real workspace first. Keep the first one simple and task-shaped, then add more drives, devices, and packages after the workspace exists.")
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
                    value: revealLocalTokens ? (auth.accessToken ?? "") : maskedToken(auth.accessToken),
                    copyLabel: "Copy Access Token",
                    copyAction: {
                        if let token = auth.accessToken {
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

private enum RecipeProgress {
    case guide
    case ready
    case done

    var label: String {
        switch self {
        case .guide: return "Guide"
        case .ready: return "Ready"
        case .done: return "Done"
        }
    }

    var tint: Color {
        switch self {
        case .guide: return .secondary
        case .ready: return .orange
        case .done: return .green
        }
    }
}

private enum SpiderwebRecipe: String, Identifiable {
    case mountExistingSpiderweb
    case shareThisSpiderweb
    case provideThisMac
    case setupUsefulWorkspace
    case packagesAndServices

    var id: String { rawValue }

    var eyebrow: String {
        switch self {
        case .mountExistingSpiderweb: return "REMOTE ACCESS"
        case .shareThisSpiderweb: return "SHARE THIS HOST"
        case .provideThisMac: return "REMOTE PAIRING"
        case .setupUsefulWorkspace: return "WORKSPACE GUIDE"
        case .packagesAndServices: return "PACKAGES AND SERVICES"
        }
    }

    var title: String {
        switch self {
        case .mountExistingSpiderweb: return "Mount an Existing Spiderweb"
        case .shareThisSpiderweb: return "Let Another Mac Connect to This Spiderweb"
        case .provideThisMac: return "Provide This Mac to a Remote Spiderweb"
        case .setupUsefulWorkspace: return "Set Up a Useful Workspace"
        case .packagesAndServices: return "Add Packages and Services"
        }
    }

    var summary: String {
        switch self {
        case .mountExistingSpiderweb:
            return "Use this when a Spiderweb is already running somewhere else and you just want its workspace as a drive on this Mac."
        case .shareThisSpiderweb:
            return "Run Spiderweb on this Mac, then share a network URL and access token so another Mac, tool, or saved drive can connect back here."
        case .provideThisMac:
            return "Use an invite token to pair this Mac as a remote device so another Spiderweb can use its files or services."
        case .setupUsefulWorkspace:
            return "A workspace is the shared root that drives, packages, and tools attach to. Start with one clear job, then expand it."
        case .packagesAndServices:
            return "Packages are Spider's installable capabilities. Older internal docs may call them venoms, but the user-facing flow should stay package-first."
        }
    }

    var steps: [String] {
        switch self {
        case .mountExistingSpiderweb:
            return [
                "Copy the remote Spiderweb URL and access token.",
                "Pick the workspace id and a mount path under ~/Spiderweb.",
                "Save the drive, then mount or reveal it from the Drives screen."
            ]
        case .shareThisSpiderweb:
            return [
                "Install / Start Service on this Mac so Spiderweb is running locally.",
                "Reveal the local access tokens and copy a network URL plus the access token.",
                "Use that URL and token from another Mac, SpiderApp, or a saved remote drive."
            ]
        case .provideThisMac:
            return [
                "Paste the remote control URL and invite token from the other Spiderweb.",
                "Choose what path this Mac should export and whether it should be read-only.",
                "Pair the Mac, then confirm it shows up in the remote workspace topology."
            ]
        case .setupUsefulWorkspace:
            return [
                "Give the workspace a recognizable name and one-sentence goal.",
                "Create the workspace first, then create a saved drive from it once it appears below.",
                "Only add more drives, devices, and packages after the workspace itself makes sense."
            ]
        case .packagesAndServices:
            return [
                "Open SpiderApp once the first workspace and drive are working.",
                "Use Capabilities to inspect installed packages and add only the next useful one.",
                "When you see the word venom in older internal docs, read it as the older term for a package or capability."
            ]
        }
    }

    var primaryButtonTitle: String {
        switch self {
        case .mountExistingSpiderweb: return "Open Remote Drive Setup"
        case .shareThisSpiderweb: return "Open Local Access"
        case .provideThisMac: return "Open Pairing Setup"
        case .setupUsefulWorkspace: return "Open Workspace Setup"
        case .packagesAndServices: return "Open Next Step"
        }
    }

    var secondaryButtonTitle: String? {
        switch self {
        case .mountExistingSpiderweb: return "Reveal Host Access"
        case .shareThisSpiderweb: return "Open Remote Drives"
        case .provideThisMac: return "Open System Settings"
        case .setupUsefulWorkspace: return "Start Local Workspace"
        case .packagesAndServices: return "Back to Overview"
        }
    }

    func progress(using controller: SpiderwebAppController) -> RecipeProgress {
        switch self {
        case .mountExistingSpiderweb:
            return controller.savedMounts.contains(where: { $0.kind == .remote }) ? .done : .guide
        case .shareThisSpiderweb:
            if controller.serviceStatus?.loaded == true,
               controller.authStatus?.accessPresent == true,
               controller.serviceStatus?.remoteReachable != false {
                return .done
            }
            if controller.serviceStatus?.loaded == true, controller.authStatus?.accessPresent == true {
                return .ready
            }
            return .guide
        case .provideThisMac:
            if controller.pairedRemoteNode != nil {
                return .done
            }
            if controller.serviceStatus?.loaded == true {
                return .ready
            }
            return .guide
        case .setupUsefulWorkspace:
            if !controller.mountableLocalWorkspaces.isEmpty {
                return .done
            }
            if controller.serviceStatus?.loaded == true {
                return .ready
            }
            return .guide
        case .packagesAndServices:
            if controller.quickstartState?.isComplete == true, controller.quickstartCanOpenSpiderApp {
                return .done
            }
            if controller.quickstartState?.isComplete == true {
                return .ready
            }
            return .guide
        }
    }
}

private struct SpiderwebRecipeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var controller: SpiderwebAppController

    let recipe: SpiderwebRecipe
    let primaryAction: () -> Void
    let secondaryAction: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(recipe.eyebrow)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                RecipeProgressBadge(progress: recipe.progress(using: controller))
            }

            Text(recipe.title)
                .font(.title2.weight(.bold))

            Text(recipe.summary)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                Text("What to do")
                    .font(.headline)
                ForEach(Array(recipe.steps.enumerated()), id: \.offset) { index, step in
                    Text("\(index + 1). \(step)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            if recipe == .packagesAndServices {
                Text(controller.quickstartCanOpenSpiderApp
                    ? "SpiderApp is available, so that is the best place to continue into packages, devices, and recipes."
                    : "If SpiderApp is not available yet, continue from the mounted drive and come back to package setup later.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 10) {
                Button(recipe.primaryButtonTitle) {
                    primaryAction()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)

                if let secondaryAction, let secondaryButtonTitle = recipe.secondaryButtonTitle {
                    Button(secondaryButtonTitle) {
                        secondaryAction()
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                Button("Close") {
                    dismiss()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 360)
    }
}

private struct RecipeProgressBadge: View {
    let progress: RecipeProgress

    var body: some View {
        Text(progress.label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(progress.tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(progress.tint.opacity(0.12), in: Capsule())
    }
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

private struct HeroFactCard: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .textSelection(.enabled)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.textBackgroundColor).opacity(0.85), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct OnboardingRecipeCard: View {
    let eyebrow: String
    let title: String
    let summary: String
    let steps: [String]
    let progress: RecipeProgress
    let buttonTitle: String?
    let action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(eyebrow.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                RecipeProgressBadge(progress: progress)
            }
            Text(title)
                .font(.headline)
            Text(summary)
                .font(.footnote)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    Text("\(index + 1). \(step)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if let buttonTitle, let action {
                Button(buttonTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(14)
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

@ViewBuilder
private func actionCard(title: String, detail: String, buttonTitle: String, action: @escaping () -> Void) -> some View {
    HStack(alignment: .top, spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        Spacer()

        Button(buttonTitle, action: action)
            .buttonStyle(.bordered)
            .controlSize(.small)
    }
    .padding(14)
    .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
}

#Preview {
    ContentView()
        .environmentObject(SpiderwebAppController())
}
