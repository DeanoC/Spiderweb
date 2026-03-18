/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The app's main SwiftUI view.
*/

import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Spiderweb FSKit")
                .font(.headline)

            Text("Native Spiderweb request mount")
            Text("mount -t spiderweb <spiderweb-request.json> <mountpoint>")
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)

            Text("Recommended CLI")
            Text("spiderweb-fs-mount --mount-backend native ... mount <mountpoint>")
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)

            Divider()

            Text("Known limitation")
                .font(.subheadline.weight(.semibold))
            Text("If a file is edited directly on the underlying host path after it has already been seen through the mount, macOS may keep serving stale contents until the file is reopened or the mount is remounted.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
