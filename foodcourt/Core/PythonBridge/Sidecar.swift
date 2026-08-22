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

    /// Tunggu server siap (polling). Return false kalau timeout atau prosesnya mati.
    func waitUntilReady(timeout: TimeInterval = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await checkHealth() { return true }
            // Tanpa pemeriksaan ini, backend yang mati seketika tetap ditunggu
            // sampai batas waktu penuh (dua jam) dengan layar diam tanpa pesan.
            if let process, !process.isRunning {
                launchError = "Backend stopped unexpectedly.\n\n\(recentLog())"
                self.process = nil
                return false
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        if process != nil {
            launchError = "Backend did not become ready in time.\n\n\(recentLog())"
        }
        return false
    }

    /// Catatan keluaran backend. Tanpa ini kegagalan di Mac orang lain tidak
    /// meninggalkan jejak apa pun yang bisa dibaca.
    nonisolated static var logURL: URL {
        AssetInstaller.assetsRoot.appendingPathComponent("backend.log")
    }

    private func recentLog() -> String {
        guard let contents = try? String(contentsOf: Self.logURL, encoding: .utf8) else {
            return "No backend log was written."
        }
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(12).joined(separator: "\n")
    }

    /// Development runtime: gunakan backend lokal terpadu jika server belum hidup.
    @discardableResult
    func ensureRunning(timeout: TimeInterval = 7_200) async -> Bool {
        if await checkHealth() { return true }
        guard process?.isRunning != true else { return await waitUntilReady(timeout: timeout) }
        guard let root = backendRoot(),
              let python = runtimePython(in: root) else {
            launchError = "Backend runtime is not available. Rebuild the app with the bundled runtime, or run scripts/setup_runtime.zsh in be/path-simulation for development."
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
        // Berkas .pyc yang ditulis ke dalam bundel merusak segel code signing,
        // sehingga macOS menolak aplikasi dengan pesan "is damaged" di Mac lain.
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        for (key, value) in offlineModelEnvironment(root: root) where environment[key] == nil {
            environment[key] = value
        }
        candidate.environment = environment
        // Keluaran diarahkan ke berkas supaya penyebab gagal bisa dibaca ulang,
        // termasuk ketika aplikasi dipakai orang lain di Mac lain.
        try? FileManager.default.createDirectory(
            at: Self.logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: Self.logURL.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: Self.logURL) {
            candidate.standardOutput = handle
            candidate.standardError = handle
        }
        do {
            try candidate.run()
            process = candidate
            launchError = nil
            return await waitUntilReady(timeout: timeout)
        } catch {
            launchError = "Backend failed to start: \(error.localizedDescription)"
            return false
        }
    }

    /// Urutan pencarian: runtime yang dibundel di dalam .app dulu, baru fallback development.
    private func backendRoot() -> URL? {
        if let bundled = bundledBackendRoot() { return bundled }
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

    /// Backend yang ikut dikemas di Foodcourt.app/Contents/Resources/backend.
    private func bundledBackendRoot() -> URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let candidate = resources.appendingPathComponent("backend", isDirectory: true)
        return FileManager.default.fileExists(atPath: candidate.appendingPathComponent("server.py").path) ? candidate : nil
    }

    private func runtimePython(in root: URL) -> URL? {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("python/bin/python3"))
        }
        // Build ramping menaruh runtime hasil unduhan di Application Support.
        candidates.append(AssetInstaller.runtimePythonURL)
        candidates += [".venv-runtime/bin/python", ".venv/bin/python"].map { root.appendingPathComponent($0) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Arahkan setiap bobot ke berkas di dalam bundel supaya runtime tidak pernah mengunduh.
    /// Nilai yang sudah diset dari luar tidak ditimpa, jadi override manual tetap jalan.
    private func offlineModelEnvironment(root: URL) -> [String: String] {
        let fm = FileManager.default
        // Bundel gemuk menyimpan bobot di dalam .app; build ramping mengunduhnya
        // ke Application Support. Yang di dalam .app menang supaya bundel lama
        // tetap berperilaku persis seperti sebelumnya.
        let searchRoots = [
            root.appendingPathComponent("models", isDirectory: true),
            AssetInstaller.modelsRoot,
        ]
        func locate(_ filename: String) -> URL? {
            searchRoots
                .map { $0.appendingPathComponent(filename) }
                .first { fm.fileExists(atPath: $0.path) }
        }
        var environment: [String: String] = [:]
        environment["USEE_MODELS_ROOT"] = AssetInstaller.modelsRoot.path

        let weights = [
            ("PRISM_YOLO", "yolo11s.pt"),
            ("PRISM_PREVIEW_YOLO", "yolo11s.pt"),
            ("PRISM_REID", "osnet_x0_25_msmt17.pt"),
        ]
        for (key, filename) in weights {
            if let url = locate(filename) { environment[key] = url.path }
        }

        if let gguf = locate("Qwen3-8B-Q4_K_M.gguf") {
            environment["FOODCOURT_LLM_MODEL_PATH"] = gguf.path
            // Model sudah lengkap di disk; matikan jalur unduhan Hugging Face.
            environment["HF_HUB_OFFLINE"] = "1"
        }

        return environment
    }

}
