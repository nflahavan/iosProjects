import SwiftUI

/// The receipt itself, to check a line against, pinch to zoom.
struct ReceiptViewer: View {
    let file: ReceiptFile
    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        NavigationStack {
            ScrollView([.vertical, .horizontal]) {
                VStack(spacing: 12) {
                    ForEach(Array(file.pages().enumerated()), id: \.offset) { _, page in
                        Image(decorative: page, scale: 1)
                            .resizable()
                            .scaledToFit()
                    }
                }
                .containerRelativeFrame(.horizontal) { width, _ in width * zoom * pinch }
            }
            .gesture(MagnifyGesture()
                .updating($pinch) { value, state, _ in state = value.magnification }
                .onEnded { zoom = min(max(zoom * $0.magnification, 1), 5) })
            .background(Color(.secondarySystemBackground))
            .navigationTitle("Receipt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .screen("receipt")
        }
    }
}
