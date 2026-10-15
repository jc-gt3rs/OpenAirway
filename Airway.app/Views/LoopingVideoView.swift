import AVFoundation
import SwiftUI

struct LoopingVideoView: NSViewRepresentable {
    let resourceName: String
    let fileExtension: String
    let shouldPlay: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PassiveVideoPlayerView {
        let playerView = PassiveVideoPlayerView()

        guard let url = Self.resourceURL(
            resourceName: resourceName,
            fileExtension: fileExtension,
            in: .main
        ) else {
            return playerView
        }

        let player = AVQueuePlayer()
        player.isMuted = true
        player.actionAtItemEnd = .none
        playerView.playerLayer.player = player

        context.coordinator.player = player
        context.coordinator.looper = AVPlayerLooper(
            player: player,
            templateItem: AVPlayerItem(url: url)
        )
        context.coordinator.setPlaying(shouldPlay)

        return playerView
    }

    func updateNSView(_ playerView: PassiveVideoPlayerView, context: Context) {
        context.coordinator.setPlaying(shouldPlay)
    }

    static func resourceURL(
        resourceName: String,
        fileExtension: String,
        in bundle: Bundle
    ) -> URL? {
        bundle.url(forResource: resourceName, withExtension: fileExtension)
            ?? bundle.url(
                forResource: resourceName,
                withExtension: fileExtension,
                subdirectory: "Onboarding"
            )
    }

    static func dismantleNSView(_ playerView: PassiveVideoPlayerView, coordinator: Coordinator) {
        coordinator.stop()
        playerView.playerLayer.player = nil
    }

    final class Coordinator {
        var player: AVQueuePlayer?
        var looper: AVPlayerLooper?

        func setPlaying(_ shouldPlay: Bool) {
            guard let player else { return }

            if shouldPlay {
                player.play()
            } else {
                player.pause()
                player.seek(to: .zero)
            }
        }

        func stop() {
            player?.pause()
            looper?.disableLooping()
            looper = nil
            player = nil
        }
    }
}
