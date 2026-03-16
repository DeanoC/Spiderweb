import SwiftUI

@available(macOS 15.4, *)
struct ContentView: View {
    @ObservedObject var controller: SpiderwebFSKitAppController

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Spiderweb FSKit")
                        .font(.title2.bold())
                    Text("Native macOS read-only namespace mounts for Spiderweb.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh") {
                    controller.refresh()
                }
            }

            GroupBox("Status") {
                VStack(alignment: .leading, spacing: 8) {
                    statusRow("Extension registered", controller.extensionRegisteredStatus)
                    statusRow("Visible via FSKit API", controller.fsKitVisibilityStatus)
                    statusRow("Filesystem bundle", controller.filesystemBundlePresent ? "Yes" : "No")
                    statusRow("Mount helper", controller.mountHelperPresent ? "Yes" : "No")
                    statusRow("Request directory", controller.requestDirectoryPath)
                    statusRow("Filesystem bundle path", controller.filesystemBundlePath)
                    statusRow("Mount helper path", controller.mountHelperPath)
                    statusRow("Extension bundle", controller.extensionPath)
                    Text("`Extension registered` comes from the last CLI probe saved into the shared app-group state. `Visible via FSKit API` is a narrower Apple API listing that may omit third-party modules even when registration is healthy.")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text("Mounts are still CLI-driven. Use `spiderweb-fs-mount --mount-backend native ... mount ~/spiderweb-demo`.")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Recent Requests") {
                if controller.recentRequests.isEmpty {
                    Text("No native mount request files have been staged yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(controller.recentRequests) { request in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(request.volumeName)
                                        .font(.headline)
                                    Text(request.mountpoint)
                                        .font(.system(.body, design: .monospaced))
                                        .textSelection(.enabled)
                                    Text(request.url.path)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 420)
    }

    private func statusRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .frame(width: 160, alignment: .leading)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
    }
}
