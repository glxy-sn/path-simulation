//
//  HistoryView.swift
//  foodcourt
//
//  Created by Shafa Tiara on 03/08/26.
//

import SwiftUI

/// Riwayat dibaca dari engine, bukan dari daftar tertulis mati.
///
/// Sebelumnya layar ini selalu menampilkan empat entri karangan ("Atrium Mall
/// Timur", "512 pengunjung"), dan hasil yang baru saja diproses tidak pernah
/// muncul di sana.
@Observable
@MainActor
final class HistoryViewModel {
    var entries: [HistoryEntry] = []
    var adaHasilAsli = false
    var errorMessage: String?
    var sedangMuat = true

    /// Dua pembaca: yang bawaan MENOLAK pecahan detik, jadi tanggal seperti
    /// "…T04:11:10.123456+00:00" gagal dibaca dan jatuh ke tahun 1 tanpa satu
    /// pun pesan galat. Engine sekarang mengirim detik bulat, tapi pembaca
    /// kedua tetap disiapkan supaya versi engine lama tidak merusak layar ini.
    private static let waktu = ISO8601DateFormatter()
    private static let waktuPecahan: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func tanggal(_ s: String) -> Date? {
        waktu.date(from: s) ?? waktuPecahan.date(from: s)
    }

    func muat(_ api: EngineAPI) async {
        sedangMuat = true
        defer { sedangMuat = false }
        do {
            let runs = try await api.runs()
            adaHasilAsli = !runs.isEmpty
            entries = runs.isEmpty ? HistoryEntry.samples : runs.map(entri)
            errorMessage = nil
        } catch {
            // Engine mati bukan berarti riwayatnya kosong. Menampilkan "belum
            // ada analisis" dalam keadaan itu membuat orang mengira hasil
            // kerjanya hilang.
            adaHasilAsli = false
            entries = []
            errorMessage = "Tidak bisa membaca riwayat — pastikan engine jalan di :8765."
        }
    }

    func hapus(_ id: String, _ api: EngineAPI) async {
        try? await api.deleteRun(id)
        await muat(api)
    }

    private func entri(_ r: RunDTO) -> HistoryEntry {
        let d = r.detik
        let durasi = d >= 60 ? "\(Int(d) / 60)m \(Int(d) % 60)s" : "\(Int(d))s"
        return HistoryEntry(
            venue: r.video,
            type: "1 kamera",
            date: Self.tanggal(r.waktu) ?? .distantPast,
            cameraCount: 1,
            visitors: r.totalVisitors,
            avgDwellSeconds: 0,
            // Mode tidak ikut tersimpan, dan memang belum berpengaruh: Mode
            // Lengkap dan Mode Cepat menghasilkan analisis yang sama persis
            // selama kalibrasi belum dibaca pipeline.
            mode: "Mode Cepat",
            runId: r.id,
            peakOccupancy: r.peakOccupancy,
            durationText: durasi,
            ukuranByte: r.ukuranByte
        )
    }
}

struct HistoryView: View {
    @Environment(\.uiScale) private var scale
    @Environment(AppRouter.self) private var router
    @Environment(AnalysisSession.self) private var session
    @Environment(Sidecar.self) private var sidecar
    @State private var vm = HistoryViewModel()

    private var api: EngineAPI { EngineAPI(http: sidecar.http) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l * scale) {
                HStack(alignment: .top) {
                    SectionHeader(
                        title: "Riwayat Analisis",
                        subtitle: vm.adaHasilAsli
                            ? "\(vm.entries.count) analisis tersimpan."
                            : "Belum ada analisis — yang tampil di bawah data contoh."
                    )
                    PrimaryButton(title: "Analisis Baru", systemImage: "plus") {
                        router.startNew()
                    }
                }

                if let e = vm.errorMessage {
                    InfoNote(text: e, systemImage: "exclamationmark.triangle")
                }

                if vm.entries.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: Space.m) {
                        ForEach(vm.entries) { entry in
                            HistoryRow(
                                entry: entry,
                                onOpen: { buka(entry) },
                                onDelete: entry.runId.map { id in
                                    { Task { await vm.hapus(id, api) } }
                                })
                        }
                    }
                }
            }
            .spad(Space.xl, [.horizontal, .top])
            .padding(.bottom, Space.xl)
        }
        .task { await vm.muat(api) }
    }

    /// Membuka HASIL LARI ITU, bukan yang terakhir diproses. Hasilnya diambil
    /// ulang dari engine karena analisis lama tidak lagi ada di memori.
    private func buka(_ entry: HistoryEntry) {
        guard let id = entry.runId else { return }
        Task {
            guard let dto = try? await api.runResult(id) else { return }
            session.result = EngineProcessingService(api: api, sidecar: sidecar).petakan(dto)
            router.openResult()
        }
    }

    private var emptyState: some View {
        VStack(spacing: Space.m) {
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Belum ada analisis").font(.headline)
            Text("Mulai dari “Analisis Baru”.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .card()
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    var onOpen: () -> Void
    /// nil untuk entri contoh — tidak ada berkas untuk dihapus.
    var onDelete: (() -> Void)?
    @State private var tanyaHapus = false

    var body: some View {
        HStack(spacing: Space.l) {
            RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                .fill(Theme.accentSoft)
                .frame(width: 64, height: 64)
                .overlay(
                    Image(systemName: "chart.bar.doc.horizontal")
                        .font(.title2)
                        .foregroundStyle(Theme.accent)
                )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: Space.s) {
                    Text(entry.venue).font(.headline)
                    Tag(text: entry.mode,
                        color: entry.mode == "Mode Lengkap" ? Theme.accent : .orange)
                }
                // Nama lari ikut ditampilkan. Tanpa ini setiap baris berbunyi
                // sama — semua analisis dari video yang sama tampil sebagai
                // "day1cam1.mp4", dan satu-satunya pembeda cuma jam. Begitu ada
                // belasan percobaan atas video yang sama, memilih yang benar
                // jadi tebak-tebakan.
                HStack(spacing: Space.s) {
                    Text("\(entry.type) · \(entry.dateText)")
                    if let id = entry.runId {
                        Text(id).monospaced()
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: Space.l) {
                    // Untuk lari sungguhan: puncak okupansi + durasi. Rata-rata
                    // dwell tidak ikut tersimpan di ringkasan, dan "0s" akan
                    // terbaca seperti tidak ada yang berhenti sama sekali.
                    if let puncak = entry.peakOccupancy {
                        stat("person.2", "\(entry.visitors) terbaca · puncak \(puncak)")
                        stat("clock", entry.durationText ?? "—")
                    } else {
                        stat("person.2", "\(entry.visitors) pengunjung")
                        stat("clock", entry.avgDwellText)
                    }
                    stat("camera", "\(entry.cameraCount) kamera")
                    if entry.ukuranByte > 0 {
                        stat("internaldrive",
                             ByteCountFormatter.string(fromByteCount: entry.ukuranByte,
                                                       countStyle: .file))
                    }
                }
                .padding(.top, 2)
            }

            Spacer()

            GhostButton(title: "Buka", systemImage: "arrow.up.right", action: onOpen)

            if let hapus = onDelete {
                Button(role: .destructive) { tanyaHapus = true } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .confirmationDialog("Hapus analisis ini?", isPresented: $tanyaHapus) {
                    Button("Hapus beserta videonya", role: .destructive, action: hapus)
                    Button("Batal", role: .cancel) {}
                } message: {
                    Text("Video beranotasi dan hasilnya dihapus permanen dari disk.")
                }
            }
        }
        .card(padding: Space.m)
    }

    private func stat(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.caption2).foregroundStyle(.secondary)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
}

#Preview {
    HistoryView()
        .environment(AppRouter())
        .environment(AnalysisSession())
        .environment(Sidecar())
        .frame(width: 1100, height: 780)
}
