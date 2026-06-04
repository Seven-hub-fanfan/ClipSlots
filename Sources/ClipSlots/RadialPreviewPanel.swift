import SwiftUI

/// v2.7.13: clean image-only preview. No material background, no rounded container,
/// no AppKit shadow. The HStack toolbar is the only top bar.
struct RadialPreviewPanel: View {
    let title: String
    let subtitle: String
    let content: AnyView
    @Binding var isPinned: Bool
    @State private var scale: CGFloat = 1

    var body: some View {
        VStack(spacing: 0) {
            // v2.7.13: use this app toolbar as the only top bar.
            HStack(spacing: 10) {
                Image(systemName: "eye")
                    .foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text("图片实时预览").font(.caption2).foregroundColor(.secondary).lineLimit(1)
                }
                Spacer()
                Button { scale = max(0.75, scale - 0.1) } label: { Image(systemName: "minus.magnifyingglass") }
                Button { scale = min(1.8, scale + 0.1) } label: { Image(systemName: "plus.magnifyingglass") }
                Button { isPinned.toggle() } label: { Image(systemName: isPinned ? "pin.fill" : "pin") }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .frame(height: 54)
            .background(Color(NSColor.windowBackgroundColor).opacity(0.96))

            Divider()

            ZStack {
                Color.clear
                content
                    .scaleEffect(scale)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
        }
        .frame(minWidth: 260, minHeight: 220)
        // v2.7.13: no material background, no rounded container, no shadow.
        .background(Color.clear)
    }
}

// MARK: - v2.7.11 Live Preview Content (v2.7.13: image-only)

struct RadialLivePreviewContent: View {
    @ObservedObject var store: SlotStoreObservable
    @State private var hoveredSlot: Int?

    var body: some View {
        Group {
            if let slot = hoveredSlot,
               let content = store.slots[slot],
               !content.isEmpty,
               content.isImageLikeForRadialPreview {
                RadialImageOnlyPreview(content: content)
                    .id(slot)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.system(size: 34))
                        .foregroundColor(.secondary)
                    Text("悬停图片槽位查看预览")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .radialMenuHoveredSlotChanged)) { note in
            hoveredSlot = note.object as? Int
        }
    }
}

// MARK: - v2.7.13 Image-Only Preview

private struct RadialImageOnlyPreview: View {
    let content: SlotContent
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let img = image ?? content.inlineImage {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { loadImageIfNeeded() }
    }

    private func loadImageIfNeeded() {
        guard image == nil else { return }
        if let inline = content.inlineImage { image = inline; return }
        guard content.isImageFile, let url = content.primaryFileURL else { return }
        if let img = NSImage(contentsOf: url) { image = img }
    }
}

// MARK: - SlotContent Helper

private extension SlotContent {
    var isImageLikeForRadialPreview: Bool {
        inlineImage != nil || isImageFile
    }
}
