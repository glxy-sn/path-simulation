//
//  CalibrationProfileLibrary.swift
//  foodcourt
//

import Foundation

struct SavedCalibrationProfile: Identifiable, Hashable {
    let id: UUID
    let displayName: String
    let savedAt: Date
    let cameraCount: Int
    let usesCanvas: Bool
    let sourceName: String
    let directoryURL: URL
}

struct ImportedCalibrationProfile {
    let profile: CalibrationProfile
    let floorPlanURL: URL?
    let securityScopedURL: URL?
}

enum CalibrationProfileLibraryError: LocalizedError {
    case unavailableStorage
    case invalidPackage
    case missingFloorPlan

    var errorDescription: String? {
        switch self {
        case .unavailableStorage: return "Penyimpanan riwayat kalibrasi tidak tersedia."
        case .invalidPackage: return "Paket profil kalibrasi tidak valid atau rusak."
        case .missingFloorPlan: return "Pilih file floor plan yang digunakan oleh profil lama ini."
        }
    }
}

enum CalibrationProfileLibrary {
    static let packageExtension = "foodcourtcalibration"
    private static let manifestName = "profile.json"

    static func list() throws -> [SavedCalibrationProfile] {
        let root = try libraryRoot()
        let urls = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        return urls.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let loaded = try? loadDirectory(url) else { return nil }
            let profile = loaded.profile
            guard let id = profile.profileID else { return nil }
            return SavedCalibrationProfile(
                id: id,
                displayName: profile.displayName ?? defaultDisplayName(venueName: profile.venueName, at: profile.savedAt ?? .distantPast),
                savedAt: profile.savedAt ?? .distantPast,
                cameraCount: profile.cameras.count,
                usesCanvas: profile.floorplan.usesCanvas,
                sourceName: profile.floorplan.sourceName,
                directoryURL: url
            )
        }
        .sorted { $0.savedAt > $1.savedAt }
    }

    static func save(session: AnalysisSession) throws -> SavedCalibrationProfile {
        guard session.allCalibrated else { throw CalibrationError.invalidProfile }
        if !session.usesScaledCanvas {
            guard let url = session.floorPlanURL, FileManager.default.fileExists(atPath: url.path) else {
                throw CalibrationError.missingFloorPlan
            }
        }

        let now = Date()
        let id = UUID()
        var profile = try CalibrationProfileStore.exportProfile(from: session)
        profile.schemaVersion = CalibrationProfile.currentSchemaVersion
        profile.profileID = id
        profile.displayName = defaultDisplayName(venueName: session.venueName, at: now)
        profile.savedAt = now
        profile.venueName = session.venueName.isEmpty ? nil : session.venueName
        let assetName = session.usesScaledCanvas ? nil : floorPlanAssetName(for: session.floorPlanURL)
        profile.floorplan.assetFileName = assetName

        let directory = try writeSnapshot(profile, floorPlanURL: session.floorPlanURL)
        return SavedCalibrationProfile(
            id: id,
            displayName: profile.displayName ?? "Profil Kalibrasi",
            savedAt: now,
            cameraCount: profile.cameras.count,
            usesCanvas: profile.floorplan.usesCanvas,
            sourceName: profile.floorplan.sourceName,
            directoryURL: directory
        )
    }

    static func load(_ record: SavedCalibrationProfile) throws -> ImportedCalibrationProfile {
        try loadDirectory(record.directoryURL)
    }

    static func inspectImport(at url: URL) throws -> ImportedCalibrationProfile {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw CalibrationProfileLibraryError.invalidPackage
        }
        if isDirectory.boolValue || url.pathExtension.lowercased() == packageExtension {
            let loaded = try loadDirectory(url)
            return ImportedCalibrationProfile(
                profile: loaded.profile,
                floorPlanURL: loaded.floorPlanURL,
                securityScopedURL: url
            )
        }
        let profile = try CalibrationProfileStore.decode(Data(contentsOf: url))
        guard (1...CalibrationProfile.currentSchemaVersion).contains(profile.schemaVersion) else {
            throw CalibrationProfileLibraryError.invalidPackage
        }
        return ImportedCalibrationProfile(profile: profile, floorPlanURL: nil, securityScopedURL: url)
    }

    static func importProfile(
        _ imported: ImportedCalibrationProfile,
        attachedFloorPlanURL: URL? = nil
    ) throws -> SavedCalibrationProfile {
        let sourceFloorPlan = imported.floorPlanURL ?? attachedFloorPlanURL
        if !imported.profile.floorplan.usesCanvas, sourceFloorPlan == nil {
            throw CalibrationProfileLibraryError.missingFloorPlan
        }

        let hasAccess = imported.securityScopedURL?.startAccessingSecurityScopedResource() == true
        defer { if hasAccess { imported.securityScopedURL?.stopAccessingSecurityScopedResource() } }
        let now = Date()
        let id = UUID()
        var profile = imported.profile
        profile.schemaVersion = CalibrationProfile.currentSchemaVersion
        profile.profileID = id
        profile.savedAt = now
        profile.displayName = profile.displayName ?? defaultDisplayName(venueName: profile.venueName, at: now)
        profile.floorplan.assetFileName = profile.floorplan.usesCanvas ? nil : floorPlanAssetName(for: sourceFloorPlan)
        let directory = try writeSnapshot(profile, floorPlanURL: sourceFloorPlan)
        return SavedCalibrationProfile(
            id: id,
            displayName: profile.displayName ?? "Profil Kalibrasi",
            savedAt: now,
            cameraCount: profile.cameras.count,
            usesCanvas: profile.floorplan.usesCanvas,
            sourceName: profile.floorplan.sourceName,
            directoryURL: directory
        )
    }

    static func delete(_ record: SavedCalibrationProfile) throws {
        let root = try libraryRoot().standardizedFileURL
        let target = record.directoryURL.standardizedFileURL
        guard target.deletingLastPathComponent() == root else {
            throw CalibrationProfileLibraryError.invalidPackage
        }
        try FileManager.default.removeItem(at: target)
    }

    static func detachedFloorPlanCopy(for record: SavedCalibrationProfile) throws -> URL? {
        let loaded = try load(record)
        guard let source = loaded.floorPlanURL else { return nil }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("foodcourt-active-floorplans", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(record.id.uuidString)-\(source.lastPathComponent)")
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    static func export(_ record: SavedCalibrationProfile, to destination: URL) throws {
        let hasAccess = destination.startAccessingSecurityScopedResource()
        defer { if hasAccess { destination.stopAccessingSecurityScopedResource() } }
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.copyItem(at: record.directoryURL, to: destination)
    }

    private static func libraryRoot() throws -> URL {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CalibrationProfileLibraryError.unavailableStorage
        }
        let root = support
            .appendingPathComponent("foodcourt", isDirectory: true)
            .appendingPathComponent("CalibrationProfiles", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func loadDirectory(_ directory: URL) throws -> ImportedCalibrationProfile {
        let manifestURL = directory.appendingPathComponent(manifestName)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw CalibrationProfileLibraryError.invalidPackage
        }
        let profile = try CalibrationProfileStore.decode(Data(contentsOf: manifestURL))
        guard (1...CalibrationProfile.currentSchemaVersion).contains(profile.schemaVersion) else {
            throw CalibrationProfileLibraryError.invalidPackage
        }
        let floorPlanURL = profile.floorplan.assetFileName.map { directory.appendingPathComponent($0) }
        if let floorPlanURL, !FileManager.default.fileExists(atPath: floorPlanURL.path) {
            throw CalibrationProfileLibraryError.invalidPackage
        }
        return ImportedCalibrationProfile(profile: profile, floorPlanURL: floorPlanURL, securityScopedURL: nil)
    }

    private static func writeSnapshot(_ profile: CalibrationProfile, floorPlanURL: URL?) throws -> URL {
        let root = try libraryRoot()
        guard let id = profile.profileID else { throw CalibrationProfileLibraryError.invalidPackage }
        let target = root.appendingPathComponent(id.uuidString, isDirectory: true)
        let temporary = root.appendingPathComponent(".\(id.uuidString).tmp", isDirectory: true)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: temporary.path) { try fileManager.removeItem(at: temporary) }
        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: false)
        do {
            if let assetName = profile.floorplan.assetFileName {
                guard let floorPlanURL else { throw CalibrationProfileLibraryError.missingFloorPlan }
                let hasAccess = floorPlanURL.startAccessingSecurityScopedResource()
                defer { if hasAccess { floorPlanURL.stopAccessingSecurityScopedResource() } }
                try fileManager.copyItem(at: floorPlanURL, to: temporary.appendingPathComponent(assetName))
            }
            try CalibrationProfileStore.encode(profile).write(
                to: temporary.appendingPathComponent(manifestName),
                options: .atomic
            )
            try fileManager.moveItem(at: temporary, to: target)
            return target
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private static func floorPlanAssetName(for url: URL?) -> String {
        let ext = url?.pathExtension.lowercased() ?? ""
        return ext.isEmpty ? "floorplan" : "floorplan.\(ext)"
    }

    private static func defaultDisplayName(venueName: String?, at date: Date) -> String {
        let venue = venueName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = venue?.isEmpty == false ? venue! : "Kalibrasi"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "id_ID")
        formatter.dateFormat = "d MMM yyyy, HH.mm.ss"
        return "\(base) — \(formatter.string(from: date))"
    }
}
