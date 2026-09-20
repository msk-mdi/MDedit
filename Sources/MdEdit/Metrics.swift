import CoreGraphics

/// Layout constants shared by every piece of chrome.
///
/// Keeping them in one place is what makes concentric corners possible: an inner
/// glass element inset from the window edge must curve by the window's radius
/// minus that inset, or its curve fights the window's.
enum Metrics {
    /// Approximate corner radius of a macOS window on Tahoe.
    static let windowCornerRadius: CGFloat = 16

    /// Standard inset of floating chrome from the window edge.
    static let chromeInset: CGFloat = 10

    /// Radius for chrome inset by `chromeInset`, concentric with the window.
    static var concentricRadius: CGFloat { windowCornerRadius - chromeInset }

    /// Height of the segmented tab track.
    static let trackHeight: CGFloat = 30

    /// Inset of the raised thumb inside the track.
    static let thumbInset: CGFloat = 2

    /// Diameter of the round "new tab" button beside the track.
    static let plusDiameter: CGFloat = 30

    /// Gap between the track and the button beside it.
    static let tabGap: CGFloat = 8

    /// Height of the bottom status bar.
    static let statusBarHeight: CGFloat = 28

    /// Width of the text column in the editor canvas.
    static let defaultLineWidth: CGFloat = 720
}
