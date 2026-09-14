import Foundation

/// Results may open only after both the evidence package and local model are ready.
@MainActor
enum AskDataPreparation {
    static func wait(
        status: () async throws -> ExplanatoryStatusDTO,
        build: () async throws -> ExplanatoryStatusDTO,
        pause: () async throws -> Void = { try await Task.sleep(for: .seconds(1)) },
        progress: (String) -> Void = { _ in }
    ) async throws {
        var current = try await status()
        if ["not_started", "stale", "error"].contains(current.state) { current = try await build() }
        let deadline = Date().addingTimeInterval(7200)
        while true {
            try Task.checkCancellation()
            if current.state == "error" || current.modelState == "error" || current.modelError != nil {
                throw NSError(domain: "AskDataPreparation", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    current.error ?? current.modelError ?? "Unable to prepare Ask Data."])
            }
            if current.state == "ready" && current.modelReady { return }
            if Date() > deadline { throw URLError(.timedOut) }
            progress(current.state == "ready" ? "Loading the language model…" :
                     "Preparing Ask Data… \(Int(max(0,min(1,current.progress))*100))%")
            try await pause()
            current = try await status()
        }
    }

    static func prepare(jobId: String?, http: HTTPClient, zones: [CustomZone], progress: (String) -> Void = { _ in }) async throws {
        guard let jobId, !jobId.isEmpty else {
            throw NSError(domain: "AskDataPreparation", code: 2, userInfo: [NSLocalizedDescriptionKey: "This saved analysis has no job data for Ask Data."])
        }
        let api = TanyaDataAPI(http: http)
        _ = try await api.updateContext(jobId: jobId, zones: zones)
        try await wait(status: { try await api.status(jobId: jobId) },
                       build: { try await api.build(jobId: jobId) }, progress: progress)
    }
}
