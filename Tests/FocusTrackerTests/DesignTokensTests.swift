import XCTest
import SwiftUI
@testable import FocusTracker

// NOTE (issue #35 — honest suite pattern): the suite has no view-hosting or
// snapshot dependency, so the ring's COLOR is pinned at the token layer —
// exactly the issue's "token-level assertions if the color is tokenized".
// The views stroke `DesignTokens.focusRing` / `.focusRingCompleted`
// directly (`TimerView`); the break ring's blue is pinned here too so a
// future palette edit cannot silently recolor `BreakView`. Whether the red
// reads calm to the USER is the visual re-test on the rebuilt binary
// (noted on the issue), not a unit assertion.

/// Token-level color assertions for the #35 focus-ring change: the exact
/// documented calm dark-theme red (running), the lighter same-family
/// completion tint (expired/completed), the break ring's pinned blue, and
/// dark-theme legibility (WCAG relative-luminance contrast) for the full
/// arc and the `pausedArcOpacity`-dimmed paused state.
final class DesignTokensTests: XCTestCase {

    // MARK: - Helpers (sRGB resolution + WCAG contrast)

    /// Resolves a SwiftUI `Color` to its sRGB components — the tokens are
    /// fixed non-adaptive colors and the app forces the dark scheme, so the
    /// authored component values are exactly what renders.
    private func sRGBComponents(of color: Color) -> (r: Double, g: Double, b: Double, a: Double) {
        let resolved = NSColor(color).usingColorSpace(.sRGB)
        XCTAssertNotNil(resolved, "color resolves in sRGB")
        guard let resolved else { return (0, 0, 0, 0) }
        return (
            Double(resolved.redComponent),
            Double(resolved.greenComponent),
            Double(resolved.blueComponent),
            Double(resolved.alphaComponent))
    }

    /// WCAG relative luminance of an sRGB color.
    private func relativeLuminance(_ c: (r: Double, g: Double, b: Double)) -> Double {
        func linearized(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearized(c.r) + 0.7152 * linearized(c.g)
            + 0.0722 * linearized(c.b)
    }

    private func contrastRatio(_ l1: Double, _ l2: Double) -> Double {
        (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    private func contrastRatio(
        _ foreground: (r: Double, g: Double, b: Double),
        _ background: (r: Double, g: Double, b: Double)
    ) -> Double {
        contrastRatio(
            relativeLuminance(foreground), relativeLuminance(background))
    }

    /// The enforced dark background (`DesignTokens.background`), fixed at
    /// `Color(white: 0.12)`.
    private var backgroundComponents: (r: Double, g: Double, b: Double) { (0.12, 0.12, 0.12) }

    // MARK: - Running ring: the documented calm dark-theme red (criterion 1)

    func testFocusRingResolvesToTheDocumentedCalmRed() {
        let c = sRGBComponents(of: DesignTokens.focusRing)
        XCTAssertEqual(c.r, 1.0, accuracy: 0.001)
        XCTAssertEqual(c.g, 0.45, accuracy: 0.001)
        XCTAssertEqual(c.b, 0.42, accuracy: 0.001)
        XCTAssertEqual(c.a, 1.0, accuracy: 0.001)
    }

    func testFocusRingIsRedDominatedAndNotAStatusPaletteReuse() {
        // A red-family hue (red channel dominant), and deliberately not a
        // reuse of the status colors the ring previously rendered with.
        let ring = sRGBComponents(of: DesignTokens.focusRing)
        XCTAssertGreaterThan(ring.r, ring.g)
        XCTAssertGreaterThan(ring.r, ring.b)
        XCTAssertNotEqual(DesignTokens.focusRing, DesignTokens.statusColor(.inProgress))
        XCTAssertNotEqual(DesignTokens.focusRingCompleted, DesignTokens.statusColor(.done))
    }

    // MARK: - Expired/completed state: lighter tint, same red family

    func testCompletedRingIsALighterTintOfTheSameRedFamily() {
        let running = sRGBComponents(of: DesignTokens.focusRing)
        let completed = sRGBComponents(of: DesignTokens.focusRingCompleted)
        // Same warm-red family: the red channel dominates in both states.
        XCTAssertGreaterThan(completed.r, completed.g)
        XCTAssertGreaterThan(completed.r, completed.b)
        // Completion is the LIGHTER family member — every channel at least
        // the running tone, green/blue strictly lighter, so the full expiry
        // circle reads as the settled "done" highlight while staying red.
        XCTAssertGreaterThanOrEqual(completed.r, running.r)
        XCTAssertGreaterThan(completed.g, running.g)
        XCTAssertGreaterThan(completed.b, running.b)
    }

    // MARK: - Break ring stays blue (issue #35 criterion 3)

    func testBreakRingColorsArePinnedUnchanged() {
        // `BreakView` strokes exactly these two status colors; pinned
        // component-exact so this issue (or any later palette edit) cannot
        // silently recolor the break ring away from its blue + green done.
        let inProgress = sRGBComponents(of: DesignTokens.statusColor(.inProgress))
        XCTAssertEqual(inProgress.r, 0.42, accuracy: 0.001)
        XCTAssertEqual(inProgress.g, 0.66, accuracy: 0.001)
        XCTAssertEqual(inProgress.b, 1.0, accuracy: 0.001)
        let done = sRGBComponents(of: DesignTokens.statusColor(.done))
        XCTAssertEqual(done.r, 0.45, accuracy: 0.001)
        XCTAssertEqual(done.g, 0.81, accuracy: 0.001)
        XCTAssertEqual(done.b, 0.56, accuracy: 0.001)
    }

    // MARK: - Dark-theme legibility (incl. the paused dim)

    func testRunningRingIsLegibleOnTheDarkBackground() {
        let ring = sRGBComponents(of: DesignTokens.focusRing)
        let ratio = contrastRatio((ring.r, ring.g, ring.b), backgroundComponents)
        // The 10pt arc clears a text-grade floor on the enforced dark
        // background (the token documents ~5.4:1; the old blue was ~5.9:1).
        XCTAssertGreaterThanOrEqual(ratio, 4.0)
    }

    func testPausedDimKeepsTheRedRingVisible() {
        // Paused composites the arc at `pausedArcOpacity` over the dark
        // background; the dimmed red must stay clearly visible — near
        // parity with the blue it replaced (~2.4:1 there, ≥2.0 pinned).
        let ring = sRGBComponents(of: DesignTokens.focusRing)
        let dimmed = (
            r: ring.r * Double(DesignTokens.pausedArcOpacity)
                + backgroundComponents.r * (1 - Double(DesignTokens.pausedArcOpacity)),
            g: ring.g * Double(DesignTokens.pausedArcOpacity)
                + backgroundComponents.g * (1 - Double(DesignTokens.pausedArcOpacity)),
            b: ring.b * Double(DesignTokens.pausedArcOpacity)
                + backgroundComponents.b * (1 - Double(DesignTokens.pausedArcOpacity)))
        let pausedRatio = contrastRatio(dimmed, backgroundComponents)
        XCTAssertGreaterThanOrEqual(pausedRatio, 2.0)
    }

    func testCompletedRingIsMoreLegibleThanTheRunningArc() {
        // The completed full circle (the expiry state) is the lighter
        // family tint — strictly more legible than the running red, so the
        // expired state is the clearest the ring ever renders.
        let running = sRGBComponents(of: DesignTokens.focusRing)
        let completed = sRGBComponents(of: DesignTokens.focusRingCompleted)
        let runningRatio = contrastRatio((running.r, running.g, running.b), backgroundComponents)
        let completedRatio = contrastRatio(
            (completed.r, completed.g, completed.b), backgroundComponents)
        XCTAssertGreaterThan(completedRatio, runningRatio)
        XCTAssertGreaterThanOrEqual(completedRatio, 6.0)
    }
}
