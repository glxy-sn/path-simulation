//
//  AssetInstaller.swift
//  foodcourt
//
//  Mengunduh runtime Python dan bobot model ke Application Support pada saat
//  aplikasi pertama dibuka, sehingga .app yang dibagikan cukup belasan megabita.
//

import CryptoKit
import Foundation
import Observation

// MARK: - Manifest

struct AssetManifest: Decodable {
    let version: String
    let assets: [AssetEntry]

    var totalBytes: Int64 { assets.reduce(0) { $0 + $1.size } }
}

struct AssetEntry: Decodable, Identifiable {
    enum Kind: String, Decodable {
        /// Arsip .tar.gz yang dibongkar ke dalam `destination`.
        case archive
        /// Berkas tunggal yang disalin apa adanya ke `destination`.
        case file
    }

    var id: String { name }
    let name: String
    let kind: Kind
    let url: URL
    let sha256: String
    let size: Int64
    /// Jalur relatif terhadap akar aset, misal "runtime" atau "models".
    let destination: String
    /// Berkas penanda yang harus ada setelah pemasangan berhasil, relatif
    /// terhadap `destination`. Dipakai untuk mendeteksi pemasangan yang utuh.
    let marker: String
}

// MARK: - Installer

@MainActor
@Observable
final class AssetInstaller {
    enum Phase: Equatable {
        case checking
        case downloading(label: String, fraction: Double, receivedBytes: Int64, totalBytes: Int64)
        case verifying(label: String)
        case installing(label: String)
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .checking

    /// Akar tempat seluruh aset dipasang. Sengaja di luar .app supaya menulis ke
    /// sini tidak pernah merusak segel code signing — itulah yang dulu membuat
    /// macOS menolak aplikasi dengan pesan "is damaged" di Mac lain.
    nonisolated static var assetsRoot: URL {
        // Override dipakai untuk pengujian supaya unduhan percobaan tidak menimpa
        // aset sungguhan milik pengguna.
        if let override = ProcessInfo.processInfo.environment["USEE_ASSETS_ROOT"] ?? ProcessInfo.processInfo.environment["FOODCOURT_ASSETS_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("U See", isDirectory: true)
    }

    nonisolated static var runtimePythonURL: URL {
        assetsRoot.appendingPathComponent("runtime/python/bin/python3", isDirectory: false)
    }

    nonisolated static var modelsRoot: URL {
        assetsRoot.appendingPathComponent("models", isDirectory: true)
    }

    private var manifestURL: URL? {
        if let override = ProcessInfo.processInfo.environment["USEE_ASSET_MANIFEST_URL"] ?? ProcessInfo.processInfo.environment["FOODCOURT_ASSET_MANIFEST_URL"],
           let url = URL(string: override) {
            return url
        }
        if let bundled = Bundle.main.object(forInfoDictionaryKey: "USeeAssetManifestURL") as? String,
           let url = URL(string: bundled) {
            return url
        }
        if let bundled = Bundle.main.object(forInfoDictionaryKey: "FoodcourtAssetManifestURL") as? String,
           let url = URL(string: bundled) {
            return url
        }
        return nil
    }

    private var installedMarker: URL { Self.assetsRoot.appendingPathComponent("installed.json") }
    private var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        // Unduhan 4,7 GB di sambungan pelan bisa memakan berjam-jam; batas bawaan
        // tujuh hari sudah cukup, tetapi dinaikkan eksplisit agar tidak bergantung
        // pada nilai bawaan yang bisa berubah.
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }()

    // MARK: Pemeriksaan

    /// Aset dianggap terpasang kalau ada runtime yang bisa dieksekusi dan setiap
    /// penanda dari manifest terpasang tercatat masih ada di disk.
    func isInstalled() -> Bool {
        guard FileManager.default.isExecutableFile(atPath: Self.runtimePythonURL.path) else { return false }
        guard let data = try? Data(contentsOf: installedMarker),
              let record = try? JSONDecoder().decode(InstalledRecord.self, from: data) else { return false }
        return record.markers.allSatisfy { FileManager.default.fileExists(atPath: Self.assetsRoot.appendingPathComponent($0).path) }
    }

    /// Aset yang sudah ikut di dalam .app (bundel gemuk lama) membuat unduhan
    /// tidak diperlukan sama sekali.
    func isBundledInApp() -> Bool {
        guard let resources = Bundle.main.resourceURL else { return false }
        return FileManager.default.isExecutableFile(atPath: resources.appendingPathComponent("python/bin/python3").path)
    }

    private struct InstalledRecord: Codable {
        let version: String
        let markers: [String]
    }

    // MARK: Pemasangan

    func install() async {
        if isBundledInApp() || isInstalled() {
            phase = .ready
            return
        }
        guard let manifestURL else {
            phase = .failed("Runtime download is not configured for this U See build. Install an offline build or rebuild it with an asset manifest URL.")
            return
        }
        // Runtime Python yang dikemas hanya arm64. Di Mac Intel bagian Swift tetap
        // jalan (binernya universal) sehingga kegagalannya baru muncul jauh
        // kemudian sebagai galat Python yang tidak bisa dimengerti pengguna.
        if let reason = unsupportedMachineReason() {
            phase = .failed(reason)
            return
        }
        if let reason = insufficientDiskReason() {
            phase = .failed(reason)
            return
        }
        do {
            phase = .checking
            let manifest = try await loadManifest(manifestURL)
            try FileManager.default.createDirectory(at: Self.assetsRoot, withIntermediateDirectories: true)
            // Dua jendela Foodcourt yang terbuka bersamaan akan menulis ke berkas
            // .part yang sama dan saling merusak; hasilnya checksum gagal terus
            // tanpa sebab yang jelas. Kunci ini membuat yang kedua menunggu.
            guard let lock = DownloadLock(at: Self.assetsRoot.appendingPathComponent("unduhan.lock")) else {
                phase = .failed("Another copy of U See is already downloading these files. Finish that one first, or quit it and try again.")
                return
            }
            defer { lock.release() }

            var completedBytes: Int64 = 0
            let totalBytes = manifest.totalBytes
            for entry in manifest.assets {
                // Berkas yang sudah benar di tempat tujuan tidak diunduh ulang.
                // Tanpa ini, pemasangan yang diulang akan menarik lagi berkas
                // 4,7 GB yang sebenarnya sudah utuh di disk.
                if try alreadyInPlace(entry) {
                    completedBytes += entry.size
                    continue
                }
                let staged = try await download(entry, completedBytes: completedBytes, totalBytes: totalBytes)
                phase = .verifying(label: entry.name)
                let digest = try sha256(of: staged)
                guard digest.caseInsensitiveCompare(entry.sha256) == .orderedSame else {
                    // Unduhan 4,7 GB lewat jaringan rumah cukup sering terpotong;
                    // tanpa pemeriksaan ini kegagalannya baru muncul jauh kemudian
                    // sebagai galat Python yang membingungkan.
                    try? FileManager.default.removeItem(at: staged)
                    throw AssetError.checksumMismatch(entry.name)
                }
                phase = .installing(label: entry.name)
                try install(entry, from: staged)
                completedBytes += entry.size
            }

            let record = InstalledRecord(
                version: manifest.version,
                markers: manifest.assets.map { "\($0.destination)/\($0.marker)" }
            )
            try JSONEncoder().encode(record).write(to: installedMarker)
            phase = .ready
        } catch is CancellationError {
            phase = .failed("Setup was cancelled.")
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Foodcourt hanya bisa berjalan di Mac dengan chip Apple.
    private func unsupportedMachineReason() -> String? {
        #if arch(arm64)
        return nil
        #else
        return "U See needs a Mac with Apple silicon (M1 or newer). This Mac uses an Intel processor, which the analysis runtime does not support."
        #endif
    }

    /// Aset butuh sekitar 6,5 GB terpasang, ditambah ruang sementara untuk berkas
    /// unduhan. Tanpa pemeriksaan ini disk penuh muncul sebagai galat tulis yang
    /// membingungkan di tengah unduhan berjam-jam.
    private func insufficientDiskReason() -> String? {
        let required: Int64 = 13_000_000_000
        guard let values = try? Self.assetsRoot.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage else { return nil }
        guard available < required else { return nil }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB]
        formatter.countStyle = .file
        return "Not enough disk space. U See needs about \(formatter.string(fromByteCount: required)) free, but only \(formatter.string(fromByteCount: available)) is available."
    }

    /// Aset berkas tunggal dapat diperiksa dengan checksum. Untuk arsip,
    /// marker hasil ekstraksi adalah bukti pemasangan yang cukup: checksum
    /// arsip sudah diverifikasi sebelum dibongkar dan arsip staging dihapus.
    /// Ini juga mencegah runtime Python diunduh ulang jika `installed.json`
    /// belum sempat tertulis pada setup sebelumnya.
    private func alreadyInPlace(_ entry: AssetEntry) throws -> Bool {
        let target = Self.assetsRoot
            .appendingPathComponent(entry.destination, isDirectory: true)
            .appendingPathComponent(entry.marker)

        if entry.kind == .archive {
            return FileManager.default.fileExists(atPath: target.path)
        }
        guard let size = (try? FileManager.default.attributesOfItem(atPath: target.path))?[.size] as? Int64,
              size == entry.size else { return false }
        phase = .verifying(label: entry.name)
        guard let digest = try? sha256(of: target) else { return false }
        return digest.caseInsensitiveCompare(entry.sha256) == .orderedSame
    }

    private func loadManifest(_ url: URL) async throws -> AssetManifest {
        let (data, _) = try await session.data(from: url)
        return try JSONDecoder().decode(AssetManifest.self, from: data)
    }

    /// Mengunduh ke berkas `.part` di samping tujuan, melanjutkan lewat header
    /// Range kalau sebagian sudah ada. Ini yang membuat sambungan putus tidak
    /// memaksa mengulang unduhan berjam-jam dari nol.
    private func download(_ entry: AssetEntry, completedBytes: Int64, totalBytes: Int64) async throws -> URL {
        let cache = Self.assetsRoot.appendingPathComponent("unduhan", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let partial = cache.appendingPathComponent(entry.name + ".part")

        var existing: Int64 = 0
        if let attributes = try? FileManager.default.attributesOfItem(atPath: partial.path),
           let size = attributes[.size] as? Int64 {
            existing = size
        }
        if existing == entry.size { return partial }
        if existing > entry.size {
            try FileManager.default.removeItem(at: partial)
            existing = 0
        }

        var request = URLRequest(url: entry.url)
        if existing > 0 { request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range") }

        if !FileManager.default.fileExists(atPath: partial.path) {
            FileManager.default.createFile(atPath: partial.path, contents: nil)
        }

        let sink = try ChunkSink(fileURL: partial, alreadyHave: existing)
        let base = completedBytes
        let total = totalBytes
        sink.onProgress = { [weak self] received in
            Task { @MainActor in
                self?.report(entry: entry, received: received, completedBytes: base, totalBytes: total)
            }
        }
        try await sink.run(request: request, session: session)
        return partial
    }

    private func report(entry: AssetEntry, received: Int64, completedBytes: Int64, totalBytes: Int64) {
        let overall = totalBytes > 0 ? Double(completedBytes + received) / Double(totalBytes) : 0
        phase = .downloading(
            label: entry.name,
            fraction: min(max(overall, 0), 1),
            receivedBytes: completedBytes + received,
            totalBytes: totalBytes
        )
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func install(_ entry: AssetEntry, from staged: URL) throws {
        let destination = Self.assetsRoot.appendingPathComponent(entry.destination, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        switch entry.kind {
        case .file:
            let target = destination.appendingPathComponent(entry.marker)
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.moveItem(at: staged, to: target)
        case .archive:
            // `tar` sistem dipakai karena mempertahankan symlink dan bit eksekusi;
            // runtime Python mati tanpa keduanya.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-xzf", staged.path, "-C", destination.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw AssetError.extractionFailed(entry.name, process.terminationStatus)
            }
            try? FileManager.default.removeItem(at: staged)
        }
    }
}

enum AssetError: LocalizedError {
    case checksumMismatch(String)
    case badResponse(String, Int)
    case extractionFailed(String, Int32)

    var errorDescription: String? {
        switch self {
        case .checksumMismatch(let name):
            return "\(name) arrived corrupted and was discarded. Check your connection and try again."
        case .badResponse(let name, let code):
            return "Could not download \(name) (HTTP \(code))."
        case .extractionFailed(let name, let code):
            return "Could not unpack \(name) (tar exit \(code))."
        }
    }
}
