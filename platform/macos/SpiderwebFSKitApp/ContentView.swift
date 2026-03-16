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

            Text("Local directory mode")
            Text("mount -t passthrough ~/Documents ~/passthrough-fs")
                .font(.system(.body, design: .monospaced))

            Text("Spiderweb request mode")
            Text("mount -t passthrough <spiderweb-request.json> <mountpoint>")
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
