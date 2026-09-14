import XCTest
import CoreGraphics
@testable import foodcourt

@MainActor
final class HeatmapRenderingTests: XCTestCase {
    func testBothHeatmapsAndPathSummaryArePreparedBeforeDisplay() async throws {
        let result = AnalysisResult(summary: SampleResult.summary, zones: [], stops: [], occupancy: [],
                                    heatmapURL: nil, pathVideoURL: nil, combinedVideoURL: nil,
                                    overlayVideos: [], blobs: [], paths: [], identityQuality: nil,
                                    fusionDiagnosticsURL: nil,
                                    observations: [.init(trackId: 1, point: CGPoint(x: 0.3, y: 0.4), t: 0),
                                                   .init(trackId: 1, point: CGPoint(x: 0.4, y: 0.5), t: 1)])
        let prepared = try await PreparedResultVisuals.prepare(result, floorplanURL: nil, widthM: 10, heightM: 7.5)
        XCTAssertNotNil(prepared.footTraffic)
        XCTAssertNotNil(prepared.timeSpent)
        XCTAssertNotNil(prepared.pathSummary)
    }

    func testOnlyTopQuarterUsesUpperColorRange() {
        let scaled = HeatmapGrid.percentileScale((1...101).map(Double.init))
        XCTAssertEqual(scaled[75], 0.5, accuracy: 0.0001)
        XCTAssertEqual(scaled.filter { $0 > 0.5 }.count, 25)
    }

    func testOldAnswerHidesComparisonAndPreservesNumbers() {
        let text = "Area ini memiliki 1.208 kunjungan dan durasi 28,5 detik. Meski durasinya lebih pendek dibanding area yang terlihat pada gambar, kunjungannya lebih tinggi."
        XCTAssertEqual(AskDataLanguage.answer(text), "Area ini memiliki 1.208 kunjungan dan durasi 28,5 detik.")
    }

    func testPublicChatTextHidesAreaNumbersAndVariables() {
        let text = AskDataLanguage.clean("Flow area 12: raw_count 25, customScore 3")
        XCTAssertTrue(text.contains("area yang terlihat pada gambar"))
        XCTAssertFalse(text.contains("raw_count"))
        XCTAssertFalse(text.contains("customScore"))
        XCTAssertTrue(text.contains("25"))
    }

    func testEmptyCellsDoNotChangeMeasuredRanks() {
        XCTAssertEqual(HeatmapGrid.percentileScale([1, 4, 10]),
                       Array(HeatmapGrid.percentileScale([0, 0, 1, 4, 10, 0])[2...4]))
        XCTAssertEqual(HeatmapGrid.percentileScale([4, 4]), [0.5, 0.5])
    }

    func testEdgesFadeWithoutChangingActivityColorInBothModes() throws {
        let grid = HeatmapGrid(width: 5, height: 1, footTraffic: [1, 0, 4, 0, 10],
                               timeSpent: [10, 0, 4, 0, 1], trackCount: 10, observationCount: 15)
        for mode in 0...1 {
            let image = try XCTUnwrap(grid.image(mode: mode, softened: false))
            let data = try XCTUnwrap(image.dataProvider?.data)
            let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
            func pixel(_ x: Int, _ y: Int) -> [Double] {
                let start = y*image.bytesPerRow+x*4
                return (0..<4).map { Double(bytes[start+$0]) }
            }
            let center = pixel(4,4), edge = pixel(0,4)
            XCTAssertLessThan(edge[3], center[3])
            for channel in 0..<3 {
                XCTAssertEqual(edge[channel]/edge[3], center[channel]/center[3], accuracy: 0.04)
            }
            XCTAssertEqual(pixel(12,4)[3], 0, "Unmeasured cell must stay transparent")
            if mode == 0 { XCTAssertGreaterThan(center[2], center[0]) }
            else { XCTAssertGreaterThan(center[0], center[2]) }
        }
    }
}
