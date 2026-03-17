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
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
