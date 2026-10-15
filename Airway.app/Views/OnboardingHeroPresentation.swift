import Foundation

enum OnboardingHeroPresentation: Equatable {
    case demoVideo(resourceName: String, fileExtension: String, shouldPlay: Bool)
    case placeholder

    static func presentation(for page: Int, reduceMotion: Bool) -> Self {
        let resourceName: String

        let fileExtension: String

        switch page {
        case 0:
            resourceName = "demo1"
            fileExtension = "mp4"
        case 1:
            resourceName = "demo2"
            fileExtension = "mp4"
        case 2:
            resourceName = "demo3"
            fileExtension = "mp4"
        case 3:
            resourceName = "demo4"
            fileExtension = "mp4"
        case 4:
            resourceName = "airway768pProRes4444"
            fileExtension = "mov"
        default:
            return .placeholder
        }

        return .demoVideo(
            resourceName: resourceName,
            fileExtension: fileExtension,
            shouldPlay: !reduceMotion
        )
    }
}
