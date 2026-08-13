//
//  Sidecar.swift
//  foodcourt
//
//  Created by Shafa Tiara on 04/08/26.
//

import Foundation
import Observation

@MainActor
@Observable
final class Sidecar {
    nonisolated let baseURL: URL
    nonisolated let http: HTTPClient
    var device: String = ""
    var isReady = false
    var launchError: String?
    @ObservationIgnored private var process: Process?

    init(baseURL: URL = URL(string: "http://127.0.0.1:8765")!) {
        self.baseURL = baseURL
        self.http = HTTPClient(baseURL: baseURL)
    }

    private struct Health: Decodable { let status: String; let device: String }

    @discardableResult
    func checkHealth() async -> Bool {
        do {
            let h: Health = try await http.get("/health")
            device = h.device
            isReady = (h.status == "ok")
            return isReady
        } catch {
            isReady = false
            return false
        }
    }

    /// Tunggu server siap (polling). Return false kalau timeout.
    func waitUntilReady(timeout: TimeInterval = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await checkHealth() { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    /// Development runtime: gunakan backend lokal terpadu jika server belum hidup.
    @discardableResult
    func ensureRunning(timeout: TimeInterval = 7_200) async -> Bool {
        if await checkHealth() { return true }
        guard process?.isRunning != true else { return await waitUntilReady(timeout: timeout) }
        guard let root = backendRoot(),
              let python = runtimePython(in: root) else {
            launchError = "Runtime backend belum tersedia. Jalankan scripts/setup_runtime.zsh di be/path-simulation."
            return false
        }
        let candidate = Process()
        candidate.executableURL = python
        candidate.arguments = [root.appendingPathComponent("server.py").path]
        candidate.currentDirectoryURL = root
        var environment = ProcessInfo.processInfo.environment
        environment["MPLBACKEND"] = "Agg"
        let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent("foodcourt-runtime-cache", isDirectory: true)
        let matplotlibCache = cacheRoot.appendingPathComponent("matplotlib", isDirectory: true)
        let ultralyticsCache = cacheRoot.appendingPathComponent("ultralytics", isDirectory: true)
        try? FileManager.default.createDirectory(at: matplotlibCache, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: ultralyticsCache, withIntermediateDirectories: true)
        environment["MPLCONFIGDIR"] = matplotlibCache.path
        environment["YOLO_CONFIG_DIR"] = ultralyticsCache.path
        environment["PYTHONUNBUFFERED"] = "1"
        candidate.environment = environment
        do {
            try candidate.run()
            process = candidate
            launchError = nil
            return await waitUntilReady(timeout: timeout)
        } catch {
            launchError = "Backend gagal dijalankan: \(error.localizedDescription)"
            return false
        }
    }

    private func backendRoot() -> URL? {
        if let configured = ProcessInfo.processInfo.environment["FOODCOURT_BACKEND_ROOT"], !configured.isEmpty {
            let url = URL(fileURLWithPath: configured, isDirectory: true)
            return FileManager.default.fileExists(atPath: url.appendingPathComponent("server.py").path) ? url : nil
        }
        // #filePath sengaja dipakai sebagai fallback development build saja.
        let uiRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let candidate = uiRoot.deletingLastPathComponent().appendingPathComponent("be/path-simulation", isDirectory: true)
        return FileManager.default.fileExists(atPath: candidate.appendingPathComponent("server.py").path) ? candidate : nil
    }

    private func runtimePython(in root: URL) -> URL? {
        let candidates = [".venv-runtime/bin/python", ".venv/bin/python"]
        return candidates.map { root.appendingPathComponent($0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

}
