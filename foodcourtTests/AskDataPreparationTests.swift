import XCTest
@testable import foodcourt

@MainActor
final class AskDataPreparationTests: XCTestCase {
    func state(_ value: String, model: Bool = true) -> ExplanatoryStatusDTO {
        .init(state: value, progress: 0.5, error: value == "error" ? "Failed" : nil,
              contextRevision: 1, packageSchemaVersion: "2.0", runtime: "llama.cpp",
              chatModel: "Qwen", modelReady: model, modelState: model ? "ready" : "loading", modelError: nil)
    }
    func testWaitsForPackageAndModel() async throws {
        var calls = 0, builds = 0, pauses = 0
        let states = [state("not_started"), state("ready", model: false), state("ready")]
        try await AskDataPreparation.wait(status: { defer { calls += 1 }; return states[calls] },
            build: { builds += 1; return self.state("building") }, pause: { pauses += 1 })
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(builds, 1)
        XCTAssertEqual(pauses, 2)
    }
    func testReadyDoesNotRebuild() async throws {
        try await AskDataPreparation.wait(status: { self.state("ready") },
            build: { XCTFail("Ready package must be reused"); return self.state("building") },
            pause: { XCTFail("No polling needed") })
    }
    func testFailureBlocksOpening() async {
        do {
            try await AskDataPreparation.wait(status: { self.state("not_started") },
                build: { self.state("error") }, pause: { XCTFail("Failed build must stop") })
            XCTFail("Preparation should fail")
        } catch { XCTAssertEqual(error.localizedDescription, "Failed") }
    }
}
