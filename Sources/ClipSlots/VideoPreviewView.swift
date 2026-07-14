import SwiftUI
import ClipSlotsKit
import AVKit

/// Safe video preview that only renders VideoPlayer after the AVPlayer is created.
/// Avoids the nil-player crash that occurs when VideoPlayer is initialised with nil.
struct VideoPreviewView: View {
    let url: URL

    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .background(Color.black)
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("正在加载视频…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .onAppear {
            guard player == nil else { return }
            let newPlayer = AVPlayer(url: url)
            player = newPlayer
            newPlayer.play()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}
