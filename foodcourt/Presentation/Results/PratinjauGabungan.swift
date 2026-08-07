//
//  PratinjauGabungan.swift
//  foodcourt
//
//  Tab Bounding Box: video tiap kamera DAN jalur/heatmap-nya, dalam satu
//  kendali putar.
//
//  Gunanya menyandingkan, bukan menghemat tempat. Kotak ID di video dan titik
//  di denah berasal dari track yang SAMA — kalau seseorang berpindah di video
//  tapi titiknya diam di denah, salah satu dari keduanya keliru, dan itu cuma
//  bisa terlihat kalau keduanya berjalan pada detik yang sama.
//
//  Waktunya diambil dari VIDEO, bukan dari jam terpisah. Jam sendiri akan
//  hanyut terhadap pemutar (frame yang dilewat, buffering), dan hanyut sedikit
//  saja sudah cukup membuat perbandingannya tidak bisa dipercaya.
//

import SwiftUI
import AVFoundation
import Observation

@Observable
final class PemutarGabungan {
    private(set) var pemutar: [(label: String, model: PemutarModel)] = []
    var sedangMain = false

    /// Lini masa bersama; diisi dari waktu pemutar pertama.
    let lini: LiniMasa

    private var pengamat: Any?

    init(lini: LiniMasa) { self.lini = lini }

    func siapkan(_ sumber: [(label: String, url: URL)], fps: Double) {
        let sama = pemutar.count == sumber.count
            && zip(pemutar, sumber).allSatisfy { $0.0.label == $0.1.label }
        guard !sama else { return }
        bersihkan()
        pemutar = sumber.map { ($0.label, PemutarModel(url: $0.url)) }
        // Semua dijeda dulu: PemutarModel memutar sendiri begitu dibuat, dan
        // panel yang langsung berjalan tanpa diminta membuat tombol putarnya
        // berbohong tentang keadaannya.
        pemutar.forEach { $0.model.hentikan() }
        sedangMain = false

        guard let utama = pemutar.first?.model else { return }
        let f = fps > 0 ? fps : 20
        pengamat = utama.player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
        ) { [weak self] t in
            guard let self, sedangMain else { return }
            lini.frame = min(lini.maks, max(0, Int(t.seconds * f)))
        }
    }

    func togel() {
        sedangMain ? jeda() : main()
    }

    func main() {
        // Kamera kedua dan seterusnya diselaraskan ke yang pertama sebelum
        // jalan. Tanpa ini keduanya hanyut sejak awal, karena tiap AVPlayer
        // mulai memutar begitu siap sendiri-sendiri.
        if let utama = pemutar.first?.model {
            let t = utama.player.currentTime()
            for (_, m) in pemutar.dropFirst() {
                m.player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
        pemutar.forEach { $0.model.player.play(); $0.model.sedangMain = true }
        sedangMain = true
    }

    func jeda() {
        pemutar.forEach { $0.model.hentikan() }
        sedangMain = false
    }

    func lompatKe(detik: Double) {
        let t = CMTime(seconds: max(0, detik), preferredTimescale: 600)
        for (_, m) in pemutar {
            m.player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
            m.waktu = detik
        }
    }

    private func bersihkan() {
        if let p = pengamat, let utama = pemutar.first?.model {
            utama.player.removeTimeObserver(p)
        }
        pengamat = nil
        pemutar.forEach { $0.model.hentikan() }
        pemutar = []
    }

    deinit { bersihkan() }
}

/// Petak 2 baris: video tiap kamera di atas, jalur dan heatmap di bawah.
struct PratinjauGabungan: View {
    let kamera: [AnalysisResult]
    let gabungkanDenah: Bool
    @Bindable var pemutar: PemutarGabungan
    var hingga: Int?
    var fusi: FusiKamera.Hasil?

    var body: some View {
        VStack(spacing: Space.s) {
            HStack(spacing: Space.s) {
                ForEach(Array(pemutar.pemutar.enumerated()), id: \.offset) { i, p in
                    panel(judul: p.label.isEmpty ? "Kamera \(i + 1)" : p.label) {
                        LapisanVideo(player: p.model.player)
                    }
                }
                if pemutar.pemutar.isEmpty {
                    panel(judul: "Video beranotasi") {
                        ZStack {
                            Color.black
                            Text("Video beranotasi tidak dirender untuk analisis ini.")
                                .font(.caption).foregroundStyle(.white.opacity(0.7))
                                .multilineTextAlignment(.center).padding()
                        }
                    }
                }
            }

            HStack(spacing: Space.s) {
                panel(judul: "Path Simulation") {
                    PathContent(paths: utama?.paths ?? [], rasio: rasio,
                                latar: latarPanel, jejak: utama?.jejak ?? [:],
                                hasil: utama, hingga: hingga, kamera: daftar, fusi: fusi)
                }
                panel(judul: "Heatmap") {
                    ZStack {
                        HeatmapView(blobs: utama?.blobs ?? [], grid: utama?.grid,
                                    rasio: rasio, latar: latarPanel, hingga: hingga,
                                    hasil: utama, kamera: daftar)
                    }
                }
            }
        }
    }

    private var utama: AnalysisResult? { kamera.first }
    private var daftar: [AnalysisResult] { gabungkanDenah ? kamera : (utama.map { [$0] } ?? []) }
    private var rasio: Double { utama?.rasioVideo ?? 16.0 / 9.0 }
    /// Di mode denah gabungan tidak ada frame kamera yang mewakili keduanya.
    private var latarPanel: URL? { gabungkanDenah ? nil : utama?.latarURL }

    private func panel<I: View>(judul: String, @ViewBuilder isi: () -> I) -> some View {
        ZStack(alignment: .topLeading) {
            isi()
            Text(judul)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
            .strokeBorder(Theme.hairline))
    }
}

/// Kendali putar untuk pratinjau gabungan: satu tombol untuk semua panel.
struct KendaliGabungan: View {
    @Bindable var pemutar: PemutarGabungan
    @Bindable var lini: LiniMasa

    var body: some View {
        HStack(spacing: Space.s) {
            Button(action: pemutar.togel) {
                Image(systemName: pemutar.sedangMain ? "pause.fill" : "play.fill")
                    .font(.caption).frame(width: 14)
            }
            .buttonStyle(.plain)

            Slider(
                value: Binding(
                    get: { Double(lini.frame) },
                    set: { baru in
                        lini.frame = Int(baru)
                        pemutar.lompatKe(detik: lini.fps > 0 ? baru / lini.fps : 0)
                    }
                ),
                in: 0...Double(max(lini.maks, 1))
            ) { sedang in
                if sedang { pemutar.jeda() }
            }
            .controlSize(.small)

            Text("\(jam(lini.detik)) / \(jam(lini.detikTotal))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func jam(_ d: Double) -> String {
        guard d.isFinite, d >= 0 else { return "0:00" }
        let t = Int(d.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}
