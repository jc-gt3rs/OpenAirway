import CoreGraphics

enum OnboardingVideoGeometry {
    private static let sourceWidth: CGFloat = 3600
    private static let sourceHeight: CGFloat = 2338

    static func width(forHeight height: CGFloat) -> CGFloat {
        (height * sourceWidth / sourceHeight).rounded()
    }
}
