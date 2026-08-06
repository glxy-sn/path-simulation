//
//  PipelineVideo.swift
//  foodcourt
//
//  Pemutar video hasil pipeline, lengkap dengan play/pause dan penggeser waktu.
//  Aplikasi ini semula tidak punya pemutar sama sekali — kotak "video" di
//  ResultsView adalah gambar statis, dan tombol play di atasnya (VideoChrome)
//  tidak bisa diklik.
//
//  Videonya TIDAK disalin ke dalam proyek — rekaman ini memuat wajah karyawan
//  dan tidak boleh ikut ter-commit. Yang dibaca hanya path di luar repo.
//

import SwiftUI
import AVFoundation
import Observation

//  CATATAN — kenapa TIDAK pakai VideoPlayer bawaan SwiftUI:
//  `VideoPlayer` membungkus AVKit.AVPlayerView, dan di macOS ini kelas itu gagal
//  dimuat saat runtime:
//      failed to demangle superclass of VideoPlayerView
//      from mangled name 'So12AVPlayerViewC'
//  Aplikasi langsung mati begitu tab Hasil dibuka. AVPlayerLayer di bawah ini
//  memakai AVFoundation saja, tidak menyentuh AVKit, dan tidak kena masalah itu.
//  Konsekuensinya kontrolnya harus dibuat sendiri — itulah kode di bawah.

@Observable
final class PemutarModel {
    let player: AVPlayer
    var sedangMain = false
    var waktu: Double = 0        // detik
    var durasi: Double = 0       // detik
    /// True saat pengguna sedang menyeret penggeser; pembaruan otomatis dijeda
    /// supaya penunjuk tidak berebut posisi dengan jari.
    var sedangGeser = false

    private var pengamat: Any?

    init(url: URL) {
        player = AVPlayer(url: url)
        player.isMuted = true

        pengamat = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
        ) { [weak self] t in
            guard let self, !self.sedangGeser else { return }
            self.waktu = t.seconds
            if self.durasi == 0,
               let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0 {
                self.durasi = d
            }
        }

        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem, queue: .main
        ) { [weak self] _ in
            self?.player.seek(to: .zero)
            self?.player.play()          // ulang terus
        }

        player.play()
        sedangMain = true
    }

    func togel() {
        if sedangMain { player.pause() } else { player.play() }
        sedangMain.toggle()
    }

    func lompatKe(_ detik: Double) {
        player.seek(to: CMTime(seconds: detik, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        waktu = detik
    }

    func hentikan() {
        player.pause()
        sedangMain = false
    }

    deinit {
        if let p = pengamat { player.removeTimeObserver(p) }
        NotificationCenter.default.removeObserver(self)
    }
}

/// NSView yang isinya satu AVPlayerLayer, menyesuaikan ukuran otomatis.
///
/// Dipakai bersama oleh layar Hasil dan pratinjau pemotongan di Import —
/// keduanya harus menghindari AVKit, jadi keduanya memakai lapisan yang sama.
struct LapisanVideo: NSViewRepresentable {
    let player: AVPlayer

    final class Wadah: NSView {
        let lapisan = AVPlayerLayer()
        init(player: AVPlayer) {
            super.init(frame: .zero)
            lapisan.player = player
            lapisan.videoGravity = .resizeAspect
            wantsLayer = true
            layer = CALayer()
            layer?.backgroundColor = NSColor.black.cgColor
            layer?.addSublayer(lapisan)
        }
        required init?(coder: NSCoder) { fatalError("tidak dipakai") }
        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)   // jangan animasikan saat resize
            lapisan.frame = bounds
            CATransaction.commit()
        }
    }

    func makeNSView(context: Context) -> NSView { Wadah(player: player) }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Pemutar video dengan tombol play/pause, penggeser waktu, dan penunjuk durasi.
struct PipelineVideo: View {
    let url: URL
    @State private var m: PemutarModel

    init(url: URL) {
        self.url = url
        _m = State(initialValue: PemutarModel(url: url))
    }

    var body: some View {
        ZStack {
            LapisanVideo(player: m.player)

            // tombol besar di tengah, hanya saat berhenti
            if !m.sedangMain {
                Button(action: m.togel) {
                    Circle().fill(.black.opacity(0.45)).frame(width: 62, height: 62)
                        .overlay(Image(systemName: "play.fill")
                            .font(.title2).foregroundStyle(.white))
                }
                .buttonStyle(.plain)
            }

            VStack {
                Spacer()
                HStack(spacing: Space.s) {
                    Button(action: m.togel) {
                        Image(systemName: m.sedangMain ? "pause.fill" : "play.fill")
                            .font(.caption).foregroundStyle(.white)
                            .frame(width: 14)
                    }
                    .buttonStyle(.plain)

                    Slider(value: Binding(
                        get: { m.waktu },
                        set: { m.lompatKe($0) }
                    ), in: 0...max(m.durasi, 0.1)) { sedang in
                        m.sedangGeser = sedang
                    }
                    .controlSize(.small)
                    .tint(.white)

                    Text("\(jam(m.waktu)) / \(jam(m.durasi))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, Space.m)
                .padding(.vertical, Space.s)
                .background(.black.opacity(0.35))
            }
        }
        .onDisappear { m.hentikan() }
    }

    private func jam(_ d: Double) -> String {
        guard d.isFinite, d >= 0 else { return "0:00" }
        let t = Int(d)
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

