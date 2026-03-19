import AppKit
import Foundation
import SwiftUI

@main
struct SpiderwebApp: App {
    @StateObject private var controller = SpiderwebAppController()

    init() {
        Self.terminateIfAnotherSpiderwebInstanceIsRunning()
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(controller)
        }
        .defaultSize(width: 1080, height: 760)

        MenuBarExtra("Spiderweb", systemImage: controller.menuBarSymbolName) {
            SpiderwebMenuBarView()
                .environmentObject(controller)
        }
        .menuBarExtraStyle(.window)
    }

    private static func terminateIfAnotherSpiderwebInstanceIsRunning() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let otherInstances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { $0.processIdentifier != currentPID }
        guard !otherInstances.isEmpty else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.terminate(nil)
        }
    }
}

private struct SpiderwebMenuBarView: View {
    @EnvironmentObject private var controller: SpiderwebAppController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Spiderweb")
                .font(.headline)

            Label(
                controller.serviceStatus?.loaded == true ? "Local service running" : "Local service needs attention",
                systemImage: controller.serviceStatus?.loaded == true ? "checkmark.circle.fill" : "exclamationmark.circle"
            )
            Label(
                controller.nativeStatus?.ready == true ? "File system ready" : "File system needs enablement",
                systemImage: controller.nativeStatus?.ready == true ? "externaldrive.fill.badge.checkmark" : "externaldrive.badge.exclamationmark"
            )

            Divider()

            if controller.mountedSavedMounts.isEmpty {
                Text("No active mounts")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(controller.mountedSavedMounts) { mount in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mount.name)
                            Text(mount.mountpoint)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Reveal") {
                            controller.reveal(mount: mount)
                        }
                        Button("Unmount") {
                            controller.unmount(mount)
                        }
                    }
                }
            }

            Divider()

            Button("Open Spiderweb") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }
            Button("Open System Settings") {
                controller.openSystemSettings()
            }
            Button("Refresh") {
                controller.refresh()
            }
            Button("Quit") {
                NSApp.terminate(nil)
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}
