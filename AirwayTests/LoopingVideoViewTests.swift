import AppKit
import AVFoundation
import Foundation
import Testing
@testable import Airway

struct LoopingVideoViewTests {
    @Test @MainActor func passivePlayerCoversItsRoundedContainerPastEveryEdge() {
        let playerView = PassiveVideoPlayerView(
            frame: NSRect(x: 0, y: 0, width: 496, height: 300)
        )

        playerView.layoutSubtreeIfNeeded()

        #expect(playerView.playerLayer.videoGravity == .resizeAspectFill)
        #expect(playerView.playerLayer.frame == playerView.bounds.insetBy(dx: -2, dy: -2))
        #expect(playerView.layer?.cornerRadius == 16)
        #expect(playerView.layer?.masksToBounds == true)
        #expect(playerView.hitTest(NSPoint(x: 100, y: 100)) == nil)
    }

    @Test func sourceAspectRatioProducesAPixelAlignedHeroWidth() {
        let width = OnboardingVideoGeometry.width(forHeight: 300)

        #expect(width == 462)
    }

    @Test func resourceURLFindsRootBundleResources() throws {
        let bundle = try temporaryBundle(resourcePath: "RootOnly.mov")

        let url = LoopingVideoView.resourceURL(
            resourceName: "RootOnly",
            fileExtension: "mov",
            in: bundle
        )

        #expect(url?.lastPathComponent == "RootOnly.mov")
    }

    @Test func resourceURLFindsOnboardingSubdirectoryResources() throws {
        let bundle = try temporaryBundle(resourcePath: "Onboarding/FinalSlide.mov")

        let url = LoopingVideoView.resourceURL(
            resourceName: "FinalSlide",
            fileExtension: "mov",
            in: bundle
        )

        #expect(url?.lastPathComponent == "FinalSlide.mov")
    }

    private func temporaryBundle(resourcePath: String) throws -> Bundle {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("bundle")
        let resourceURL = rootURL.appendingPathComponent(resourcePath)

        try FileManager.default.createDirectory(
            at: resourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: resourceURL.path, contents: Data())

        guard let bundle = Bundle(url: rootURL) else {
            throw NSError(domain: "LoopingVideoViewTests", code: 1)
        }

        return bundle
    }
}
