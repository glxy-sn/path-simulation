//
//  EngineProcessingService.swift
//  foodcourt
//
//  Created by Shafa Tiara on 04/08/26.
//
import Foundation
import CoreGraphics

struct EngineProcessingService: ProcessingService {
    let api: EngineAPI
    let sidecar: Sidecar

    private let palette: [UInt] = [0x5457D6, 0xF59E0B, 0x22C55E, 0xEC4899, 0x14B8A6, 0x3B82F6]

    func run(_ session: AnalysisSession) -> AsyncThrowingStream<ProcessingUpdate, Error> {
        // Rakit request sinkron di sini (di pemanggil), lalu Task cuma pegang DTO Sendable.
        let built: JobRequestDTO
        do { built = try buildRequest(session) }
        catch { return AsyncThrowingStream { $0.finish(throwing: error) } }

        let api = self.api
        let sidecar = self.sidecar
        let baseURL = sidecar.baseURL
        let palette = self.palette

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard await sidecar.waitUntilReady() else { throw EngineError.notReady }
                    let jobId = try await api.createJob(built)

                    while true {
                        try Task.checkCancellation()
                        let p = try await api.progress(jobId)
                        if p.status == "error" { throw EngineError.job(p.error ?? "job failed") }
                        continuation.yield(.progress(stage: p.stage, fraction: p.fraction))
                        if p.status == "done" { break }
                        try await Task.sleep(for: .milliseconds(500))
                    }

                    let dto = try await api.result(jobId)
                    continuation.yield(.finished(Self.map(dto, palette: palette, baseURL: baseURL)))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: build request

    private func buildRequest(_ s: AnalysisSession) throws -> JobRequestDTO {
        guard !s.cameras.isEmpty else { throw EngineError.job("No cameras yet.") }
        guard let range = EngineRequestBuilder.synchronizedRange(
            cameras: s.cameras,
            requestedStart: s.trimStartSec,
            requestedEnd: s.trimEndSec
        ) else {
            throw EngineError.job("Camera offsets leave no valid shared time range.")
        }
        let duration = range.end - range.start
        let cams = try s.cameras.map {
            try EngineRequestBuilder.camera($0, globalStart: range.start, duration: duration)
        }
        let venue = EngineRequestBuilder.venue(from: s)
        return JobRequestDTO(
            venue: venue,
            mode: s.mode == .lengkap ? "lengkap" : "cepat",
            cameras: cams,
            options: JobOptionsDTO(renderVideos: true)
        )
    }

    // MARK: map hasil -> model UI (static: hanya nilai Sendable)

    private static func map(_ dto: JobResultDTO, palette: [UInt], baseURL: URL) -> AnalysisResult {
        func artifactURL(_ uri: String?) -> URL? {
            guard let uri else { return nil }
            guard uri.hasPrefix("file://") else { return URL(string: uri) }
            let raw = String(uri.dropFirst("file://".count))
            let path = raw.removingPercentEncoding ?? raw
            var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
            comps?.path = "/artifacts"
            comps?.queryItems = [URLQueryItem(name: "path", value: path)]
            return comps?.url
        }

        let zones = dto.zones.enumerated().map { i, z in
            ZoneRank(rank: i + 1, code: z.code, visits: z.visits, share: z.share,
                     rect: CGRect(x: z.rect.x, y: z.rect.y, width: z.rect.w, height: z.rect.h),
                     colorHex: palette[i % palette.count])
        }
        let stops = dto.stopPoints.map { StopPoint(name: $0.label, dwellSeconds: $0.dwellSeconds,
                                                   point: CGPoint(x: $0.x, y: $0.y)) }
        let occ = dto.occupancy.map { OccupancyPoint(minute: $0.minute, count: $0.count) }
        let summary = VenueSummary(
            totalVisitors: dto.summary.totalVisitors,
            avgDwellSeconds: dto.summary.avgDwellSeconds,
            peakOccupancy: dto.summary.peakOccupancy,
            captureRate: dto.summary.captureRate
        )
        let overlays: [(cam: String, url: URL)] = (dto.artifacts.overlayVideos ?? []).compactMap {
            guard let u = artifactURL($0.uri) else { return nil }
            return (cam: $0.cam, url: u)
        }
        let blobs = (dto.blobs ?? []).map { HeatBlob(x: $0.x, y: $0.y, intensity: $0.intensity, radius: $0.radius) }
        let paths = (dto.paths ?? []).map { p in
            PathTrace(points: p.points.map { CGPoint(x: $0.x, y: $0.y) },
                      hue: p.hue,
                      times: p.points.map { $0.t })
        }
        let quality = dto.identityQuality.map {
            IdentityQualitySummary(
                globalIDs: $0.globalIds,
                localStitches: $0.localStitches,
                overlapMerges: $0.overlapMerges,
                handoverMerges: $0.handoverMerges,
                unmatchedTracklets: $0.unmatchedTracklets,
                filteredTracklets: $0.filteredTracklets,
                highConfidence: $0.highConfidence,
                mediumConfidence: $0.mediumConfidence,
                lowConfidence: $0.lowConfidence,
                singleCamera: $0.singleCamera,
                calibrationWarnings: $0.calibrationWarnings
            )
        }
        let observations = (dto.observations ?? []).compactMap { a -> TrackObservation? in
            a.count >= 4 ? TrackObservation(trackId: Int(a[0]), point: CGPoint(x: a[1], y: a[2]), t: a[3]) : nil
        }
        return AnalysisResult(
            jobId: dto.jobId,
            summary: summary, zones: zones, stops: stops, occupancy: occ,
            heatmapURL: artifactURL(dto.artifacts.heatmapImage),
            pathVideoURL: artifactURL(dto.artifacts.pathVideo),
            combinedVideoURL: artifactURL(dto.artifacts.combinedVideo),
            overlayVideos: overlays,
            blobs: blobs, paths: paths,
            identityQuality: quality,
            fusionDiagnosticsURL: artifactURL(dto.artifacts.fusionDiagnostics),
            observations: observations
        )
    }
}
