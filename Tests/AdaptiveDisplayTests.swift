import Foundation
import Testing
@testable import GlideCore

struct AdaptiveDisplayTests {
    @Test func compactAndExpandedUseAvailableWidth() {
        let phone = MediaGridPlan.make(width: 360, minimum: 100)
        let inner = MediaGridPlan.make(width: 860, minimum: 140)
        #expect(phone.widths.count == 3)
        #expect(inner.widths.count == 5)
        #expect(abs(phone.widths.reduce(0,+) + phone.spacings.reduce(0,+) - 360) < 0.001)
        #expect(abs(inner.widths.reduce(0,+) + inner.spacings.reduce(0,+) - 860) < 0.001)
    }
    @Test func activeDivisionUsesAsymmetricSidesAndKeepsGutterClear() {
        let plan = MediaGridPlan.make(width: 900, minimum: 130, verticalDivision: DisplayDivision(lower: 400, upper: 450))
        #expect(plan.widths.count == 4)
        #expect(abs(plan.widths[0] - 194) < 0.001)
        #expect(abs(plan.widths[2] - 219) < 0.001)
        #expect(plan.spacings[1] == 50)
        #expect(abs(plan.widths.reduce(0,+) + plan.spacings.reduce(0,+) - 900) < 0.001)
    }
    @Test func inactiveFoldPrefersEvenColumnsAndAccessibilityOneColumn() {
        #expect(MediaGridPlan.make(width: 860, minimum: 140, hasDivision: true).widths.count == 4)
        #expect(MediaGridPlan.make(width: 860, minimum: 140, singleColumn: true, hasDivision: true).widths == [860])
    }
    @Test func invalidGeometryAndLargeFiniteInputsAreBounded() {
        for width in [0, -1, Double.nan, .infinity] { #expect(MediaGridPlan.make(width: width, minimum: 100).widths.isEmpty) }
        #expect(MediaGridPlan.make(width: 1000, minimum: 0).widths.isEmpty)
        #expect(MediaGridPlan.make(width: 1e100, minimum: 1).widths.count == 10)
    }
    @Test func resizingKeepsZoomFocalPointWithinBounds() {
        let result = VideoViewport.offset(CGSize(width: 50, height: -100), from: CGSize(width: 400, height: 800), to: CGSize(width: 800, height: 400), zoom: 2)
        #expect(result == CGSize(width: 100, height: -50))
        #expect(VideoViewport.offset(CGSize(width: 999, height: -999), from: CGSize(width: 400, height: 800), to: CGSize(width: 800, height: 400), zoom: 2) == CGSize(width: 400, height: -200))
        #expect(VideoViewport.offset(CGSize(width: 1, height: 1), from: CGSize(width: 0, height: 0), to: CGSize(width: 800, height: 400), zoom: 2) == CGSize(width: 0, height: 0))
        #expect(VideoViewport.offset(CGSize(width: 1, height: 1), from: CGSize(width: 400, height: 800), to: CGSize(width: CGFloat.infinity, height: 400), zoom: 2) == CGSize(width: 0, height: 0))
    }
    @Test func navigationDestinationRoundTripsAcrossSceneStorage() throws {
        for section in AppSection.allCases {
            #expect(AppSection(rawValue: section.rawValue) == section)
            #expect(try JSONDecoder().decode(AppSection.self, from: JSONEncoder().encode(section)) == section)
        }
    }
    @Test func legacyNavigationRestoresToVisibleDestination() throws {
        let oldValues=["downloads":AppSection.tasks,"sources":.library,"settings":.library,"home":.home,"library":.library,"personal":.personal]
        for (stored,expected) in oldValues {
            let decoded=try JSONDecoder().decode(AppSection.self,from:Data(("\""+stored+"\"").utf8))
            #expect(decoded.primaryDestination == expected)
            #expect(AppSection.primary.contains(decoded.primaryDestination))
        }
        #expect(Set(AppSection.primary).count == 4)
    }

}
