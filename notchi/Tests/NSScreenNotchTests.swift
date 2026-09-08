import AppKit
import XCTest
@testable import notchi

final class NSScreenNotchTests: XCTestCase {
    func testNonNotchSizeMatchesMenuBarHeight() {
        let size = NSScreen.nonNotchSize(menuBarHeight: 25)
        XCTAssertEqual(size, CGSize(width: 224, height: 25))
    }

    func testNonNotchSizeFallsBackWhenMenuBarIsHidden() {
        let size = NSScreen.nonNotchSize(menuBarHeight: 0)
        XCTAssertEqual(size, CGSize(width: 224, height: 24))
    }

    func testHeaderSpriteFitScaleShrinksBelowReferenceHeightOnNonNotchScreens() {
        XCTAssertEqual(
            NotchContentView.headerSpriteFitScale(notchHeight: 34, screenHasNotch: false),
            34.0 / 38.0,
            accuracy: 0.0001
        )
    }

    func testHeaderSpriteFitScaleFloorsAtMinimumForShortMenuBars() {
        XCTAssertEqual(NotchContentView.headerSpriteFitScale(notchHeight: 24, screenHasNotch: false), 0.8)
    }

    func testHeaderSpriteFitScaleNeverExceedsOne() {
        XCTAssertEqual(NotchContentView.headerSpriteFitScale(notchHeight: 50, screenHasNotch: false), 1)
    }

    func testHeaderSpriteFitScaleIsUnchangedOnNotchedScreens() {
        XCTAssertEqual(NotchContentView.headerSpriteFitScale(notchHeight: 35, screenHasNotch: true), 1)
    }
}
