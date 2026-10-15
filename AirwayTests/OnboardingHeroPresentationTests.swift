import Testing
@testable import Airway

struct OnboardingHeroPresentationTests {
    @Test func firstSlidePlaysDemoVideo() {
        let presentation = OnboardingHeroPresentation.presentation(
            for: 0,
            reduceMotion: false
        )

        #expect(
            presentation == .demoVideo(
                resourceName: "demo1",
                fileExtension: "mp4",
                shouldPlay: true
            )
        )
    }

    @Test func firstSlidePausesDemoVideoForReduceMotion() {
        let presentation = OnboardingHeroPresentation.presentation(
            for: 0,
            reduceMotion: true
        )

        #expect(
            presentation == .demoVideo(
                resourceName: "demo1",
                fileExtension: "mp4",
                shouldPlay: false
            )
        )
    }

    @Test func secondSlidePlaysDemoVideo() {
        let presentation = OnboardingHeroPresentation.presentation(
            for: 1,
            reduceMotion: false
        )

        #expect(
            presentation == .demoVideo(
                resourceName: "demo2",
                fileExtension: "mp4",
                shouldPlay: true
            )
        )
    }

    @Test func secondSlidePausesDemoVideoForReduceMotion() {
        let presentation = OnboardingHeroPresentation.presentation(
            for: 1,
            reduceMotion: true
        )

        #expect(
            presentation == .demoVideo(
                resourceName: "demo2",
                fileExtension: "mp4",
                shouldPlay: false
            )
        )
    }

    @Test func thirdSlidePlaysDemoVideo() {
        let presentation = OnboardingHeroPresentation.presentation(
            for: 2,
            reduceMotion: false
        )

        #expect(
            presentation == .demoVideo(
                resourceName: "demo3",
                fileExtension: "mp4",
                shouldPlay: true
            )
        )
    }

    @Test func thirdSlidePausesDemoVideoForReduceMotion() {
        let presentation = OnboardingHeroPresentation.presentation(
            for: 2,
            reduceMotion: true
        )

        #expect(
            presentation == .demoVideo(
                resourceName: "demo3",
                fileExtension: "mp4",
                shouldPlay: false
            )
        )
    }

    @Test func fourthSlidePlaysDemoVideo() {
        let presentation = OnboardingHeroPresentation.presentation(
            for: 3,
            reduceMotion: false
        )

        #expect(
            presentation == .demoVideo(
                resourceName: "demo4",
                fileExtension: "mp4",
                shouldPlay: true
            )
        )
    }

    @Test func fourthSlidePausesDemoVideoForReduceMotion() {
        let presentation = OnboardingHeroPresentation.presentation(
            for: 3,
            reduceMotion: true
        )

        #expect(
            presentation == .demoVideo(
                resourceName: "demo4",
                fileExtension: "mp4",
                shouldPlay: false
            )
        )
    }

    @Test func finalSlidePlaysLiquidLightVideo() {
        let presentation = OnboardingHeroPresentation.presentation(
            for: 4,
            reduceMotion: false
        )

        #expect(
            presentation == .demoVideo(
                resourceName: "airway768pProRes4444",
                fileExtension: "mov",
                shouldPlay: true
            )
        )
    }

    @Test func finalSlidePausesLiquidLightVideoForReduceMotion() {
        let presentation = OnboardingHeroPresentation.presentation(
            for: 4,
            reduceMotion: true
        )

        #expect(
            presentation == .demoVideo(
                resourceName: "airway768pProRes4444",
                fileExtension: "mov",
                shouldPlay: false
            )
        )
    }

    @Test func laterSlidesKeepTheirPlaceholder() {
        #expect(
            OnboardingHeroPresentation.presentation(for: 5, reduceMotion: false)
                == .placeholder
        )
    }
}
