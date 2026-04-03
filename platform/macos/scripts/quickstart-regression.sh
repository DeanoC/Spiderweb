#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DIR="$MACOS_DIR/SpiderwebFSKitApp"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

cp "$APP_DIR/SpiderwebAppController.swift" "$TMPDIR/SpiderwebAppController.swift"
cp "$APP_DIR/SpiderAppWorkflowStore.swift" "$TMPDIR/SpiderAppWorkflowStore.swift"
cp "$APP_DIR/SpiderwebSetupModel.swift" "$TMPDIR/SpiderwebSetupModel.swift"

python3 - <<'PY' "$TMPDIR/SpiderwebAppController.swift"
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
marker = "\n#Preview {"
idx = text.find(marker)
if idx != -1:
    text = text[:idx] + "\n"
path.write_text(text)
PY

cat > "$TMPDIR/QuickstartRegression.swift" <<'SWIFT'
import Foundation
import AppKit
import SwiftUI

@discardableResult
func expect(_ condition: @autoclosure () -> Bool, _ message: String) -> Bool {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        Foundation.exit(1)
    }
    return true
}

func makeWorkspace(
    id: String,
    name: String,
    kind: String = "normal",
    mountCount: Int = 1
) -> SpiderwebWorkspaceSummary {
    SpiderwebWorkspaceSummary(
        id: id,
        name: name,
        status: "active",
        kind: kind,
        mountCount: mountCount
    )
}

func makeMount(
    id: String,
    name: String,
    workspaceID: String,
    mountpoint: String
) -> SpiderwebSavedMount {
    SpiderwebSavedMount(
        id: id,
        name: name,
        kind: .local,
        serverURL: SpiderwebAppController.localServerURL,
        workspaceID: workspaceID,
        authSource: .localRuntime,
        mountpoint: mountpoint,
        createdAt: Date(timeIntervalSinceReferenceDate: 10),
        updatedAt: Date(timeIntervalSinceReferenceDate: 10),
        lastError: nil,
        lastMountState: .idle
    )
}

func makeServiceStatus() -> SpiderwebServiceStatusSnapshot {
    SpiderwebServiceStatusSnapshot(
        manager: "launchd",
        unitPath: "/tmp/spiderweb.plist",
        installed: true,
        loaded: true,
        bind: "127.0.0.1",
        port: 18790,
        remoteReachable: false
    )
}

func makeNativeStatus(ready: Bool = true) -> SpiderwebNativeStatusSnapshot {
    SpiderwebNativeStatusSnapshot(
        registered: true,
        moduleEnabled: ready,
        ready: ready,
        filesystemBundlePresent: true,
        runtimeReady: ready,
        notes: nil
    )
}

@main
struct QuickstartRegression {
    static func main() throws {
        let now = Date(timeIntervalSinceReferenceDate: 1234)

        let switched = SpiderwebAppController.initialQuickstartState(
            currentState: QuickstartState(
                preset: .justTryIt,
                currentStep: .ensureMount,
                workspaceID: "ws-old",
                workspaceName: "My Workspace",
                mountID: "mount-old",
                mountpoint: "/tmp/old",
                lastMessage: "old",
                blockedReason: "blocked",
                updatedAt: Date(timeIntervalSinceReferenceDate: 1),
                result: nil
            ),
            preset: .agentLab,
            now: now
        )
        expect(switched.preset == .agentLab, "preset switching should update the preset")
        expect(switched.currentStep == .installService, "preset switching should restart from install_service")
        expect(switched.workspaceID == nil && switched.mountID == nil, "preset switching should clear previous workspace and mount ids")
        expect(switched.workspaceName == "Agent Lab", "preset switching should reset the workspace name")
        expect(switched.mountpoint == SpiderwebAppController.quickstartMountpoint(for: "Agent Lab"), "preset switching should reset the mountpoint")
        expect(switched.lastMessage == "Switching to agent lab...", "preset switching should use the switching status message")

        let resumed = SpiderwebAppController.initialQuickstartState(
            currentState: QuickstartState(
                preset: .justTryIt,
                currentStep: .ensureWorkspace,
                workspaceID: nil,
                workspaceName: "My Workspace",
                mountID: nil,
                mountpoint: nil,
                lastMessage: "blocked",
                blockedReason: "approval needed",
                updatedAt: Date(timeIntervalSinceReferenceDate: 2),
                result: nil
            ),
            preset: .justTryIt,
            now: now
        )
        expect(resumed.currentStep == .ensureWorkspace, "same-preset resume should keep the current step")
        expect(resumed.blockedReason == nil, "same-preset resume should clear the blocked reason")
        expect(resumed.mountpoint == SpiderwebAppController.quickstartMountpoint(for: "My Workspace"), "same-preset resume should fill a missing mountpoint")
        expect(resumed.lastMessage == "Continuing start local workspace...", "same-preset resume should use the continuing status message")

        let encoder = JSONEncoder()
        let persisted = QuickstartState(
            preset: .justTryIt,
            currentStep: .enableFileSystem,
            workspaceID: nil,
            workspaceName: "My Workspace",
            mountID: nil,
            mountpoint: SpiderwebAppController.quickstartMountpoint(for: "My Workspace"),
            lastMessage: "Enable Spiderweb file system in System Settings, then resume.",
            blockedReason: "Open System Settings, enable Spiderweb file system, then return and resume.",
            updatedAt: now,
            result: nil
        )
        let roundTrip = try JSONDecoder().decode(QuickstartState.self, from: encoder.encode(persisted))
        let reconciled = SpiderwebAppController.reconciledQuickstartState(
            from: roundTrip,
            serviceStatus: makeServiceStatus(),
            nativeStatus: makeNativeStatus(),
            workspaces: [],
            mounts: [],
            activeMountpoints: [],
            now: now
        )
        expect(reconciled?.currentStep == .ensureWorkspace, "a persisted blocked approval state should resume into ensure_workspace once the filesystem is ready")
        expect(reconciled?.blockedReason == nil, "resume reconciliation should clear the blocked reason")
        expect(reconciled?.workspaceName == "My Workspace", "resume reconciliation should preserve the workspace name")

        let unrelatedResume = SpiderwebAppController.reconciledQuickstartState(
            from: QuickstartState(
                preset: .justTryIt,
                currentStep: .ensureWorkspace,
                workspaceID: nil,
                workspaceName: "My Workspace",
                mountID: nil,
                mountpoint: SpiderwebAppController.quickstartMountpoint(for: "My Workspace"),
                lastMessage: "Workspace pending",
                blockedReason: nil,
                updatedAt: now,
                result: nil
            ),
            serviceStatus: makeServiceStatus(),
            nativeStatus: makeNativeStatus(),
            workspaces: [makeWorkspace(id: "ws-9", name: "Another Test")],
            mounts: [],
            activeMountpoints: [],
            now: now
        )
        expect(unrelatedResume == nil, "relaunch reconciliation should not adopt an unrelated workspace")

        let mountResume = SpiderwebAppController.reconciledQuickstartState(
            from: QuickstartState(
                preset: .justTryIt,
                currentStep: .ensureMount,
                workspaceID: nil,
                workspaceName: "My Workspace",
                mountID: nil,
                mountpoint: SpiderwebAppController.quickstartMountpoint(for: "My Workspace"),
                lastMessage: "Drive pending",
                blockedReason: nil,
                updatedAt: now,
                result: nil
            ),
            serviceStatus: makeServiceStatus(),
            nativeStatus: makeNativeStatus(),
            workspaces: [makeWorkspace(id: "ws-12", name: "My Workspace")],
            mounts: [makeMount(id: "mount-12", name: "My Workspace", workspaceID: "ws-12", mountpoint: SpiderwebAppController.quickstartMountpoint(for: "My Workspace"))],
            activeMountpoints: [],
            now: now
        )
        expect(mountResume?.currentStep == .mountDrive, "resume reconciliation should move into mount_drive when the matching saved drive exists but is not mounted")
        expect(mountResume?.mountID == "mount-12", "resume reconciliation should adopt the matching saved drive")

        expect(
            SpiderwebAppController.shouldTreatQuickstartMountFailureAsSatisfied(
                errorMessage: "The file couldn’t be saved because a file with the same name already exists.",
                mountpoint: "/tmp/workspace",
                activeMountpoints: ["/tmp/workspace"]
            ),
            "already-mounted native mount errors should be treated as satisfied when the mountpoint is active"
        )
        expect(
            !SpiderwebAppController.shouldTreatQuickstartMountFailureAsSatisfied(
                errorMessage: "Authentication failed.",
                mountpoint: "/tmp/workspace",
                activeMountpoints: ["/tmp/workspace"]
            ),
            "non-mount-collision errors should still fail"
        )
        expect(
            !SpiderwebAppController.shouldTreatQuickstartMountFailureAsSatisfied(
                errorMessage: "The file couldn’t be saved because a file with the same name already exists.",
                mountpoint: "/tmp/workspace",
                activeMountpoints: []
            ),
            "collision text without an active mountpoint should still fail"
        )
        expect(
            SpiderwebAppController.shouldTreatQuickstartMountFailureAsSatisfied(
                errorMessage: "Native mount timed out after 20 seconds.",
                mountpoint: "/tmp/workspace",
                activeMountpoints: ["/tmp/workspace"]
            ),
            "timeout text with an active mountpoint should be treated as satisfied"
        )
        expect(
            SpiderwebAppController.shouldCompleteQuickstartWithoutMountedDrive(
                errorMessage: "Native mount timed out after 20 seconds.",
                mountpoint: "/tmp/workspace",
                activeMountpoints: []
            ),
            "timeout text without an active mountpoint should degrade into workspace-ready fallback"
        )
        expect(
            !SpiderwebAppController.shouldCompleteQuickstartWithoutMountedDrive(
                errorMessage: "Authentication failed.",
                mountpoint: "/tmp/workspace",
                activeMountpoints: []
            ),
            "non-timeout errors should still fail the quickstart"
        )

        print("quickstart regression checks passed")
    }
}
SWIFT

swiftc \
  -o "$TMPDIR/quickstart-regression" \
  "$TMPDIR/QuickstartRegression.swift" \
  "$TMPDIR/SpiderAppWorkflowStore.swift" \
  "$TMPDIR/SpiderwebAppController.swift" \
  "$TMPDIR/SpiderwebSetupModel.swift"

"$TMPDIR/quickstart-regression"
