//
//  TrimControl.swift
//  foodcourt
//
//  Created by Shafa Tiara on 04/08/26.
//

import SwiftUI
import AVFoundation

//  JANGAN kembalikan `import AVKit` dan `VideoPlayer` di berkas ini.
//  `VideoPlayer` membungkus AVKit.AVPlayerView, dan di macOS kelas itu gagal
//  dimuat saat runtime:
//      failed to demangle superclass of VideoPlayerView
//  Akibatnya aplikasi MATI seketika begitu video diimpor — pratinjau di bawah
//  muncul tepat setelah berkas dipilih. LapisanVideo memakai AVFoundation
//  saja dan tidak kena masalah itu; kontrolnya dibuat sendiri.

struct GlobalTrimCard: View {
    @Binding var startSec: Double
    @Binding var endSec: Double
    let maxSec: Double
    var previewURL: URL? = nil

    @State private var player = AVPlayer()
    @State private var loadedURL: URL? = nil
    @State private var sedangMain = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Rentang Waktu").font(.headline)
                    Text("Berlaku untuk semua kamera · total \(timecode(maxSec))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Tag(text: timecode(endSec - startSec))
            }

            // Preview video (native controls: play/pause/scrub)
            Group {
                if previewURL != nil {
                    ZStack(alignment: .bottomLeading) {
                        LapisanVideo(player: player)
                        // Kontrol bawaan AVKit hilang bersama VideoPlayer,
                        // jadi play/pause-nya dibuat sendiri. Penggeser waktu
                        // tidak perlu — RangeSlider di bawah sudah men-seek.
                        Button {
                            if sedangMain { player.pause() } else { player.play() }
                            sedangMain.toggle()
                        } label: {
                            Image(systemName: sedangMain ? "pause.fill" : "play.fill")
                                .font(.caption).foregroundStyle(.white)
                                .padding(Space.s)
                                .background(.black.opacity(0.45), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .padding(Space.s)
                    }
                        .frame(height: 260)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                                .strokeBorder(Theme.hairline)
                        )
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                            .frame(height: 260)
                        VStack(spacing: Space.s) {
                            Image(systemName: "film").font(.system(size: 30)).foregroundStyle(.secondary)
                            Text("Preview muncul setelah video punya file.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            RangeSlider(lower: $startSec, upper: $endSec, maxSec: maxSec,
                        onScrub: { t in seek(to: t) })

            HStack {
                stat("Mulai", timecode(startSec))
                Spacer()
                stat("Durasi", timecode(endSec - startSec))
                Spacer()
                stat("Selesai", timecode(endSec))
            }
        }
        .card()
        .onAppear { loadPlayer() }
        .onChange(of: previewURL) { _, _ in loadPlayer() }
    }

    private func loadPlayer() {
        guard let url = previewURL else { return }
        if url == loadedURL { return }
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        loadedURL = url
        // Video baru selalu mulai dalam keadaan jeda; tanpa ini ikon tombol
        // bisa menunjukkan "pause" padahal videonya diam.
        player.pause()
        sedangMain = false
        player.isMuted = true
        seek(to: startSec)
    }

    private func seek(to t: Double?) {
        guard let t else { return }
        player.pause()
        let tol = CMTime(seconds: 0.3, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                    toleranceBefore: tol, toleranceAfter: tol)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit().weight(.medium))
        }
    }
}

// MARK: - Range slider (dua handle)

struct RangeSlider: View {
    @Binding var lower: Double
    @Binding var upper: Double
    let maxSec: Double
    var minGap: Double = 1
    var onScrub: (Double?) -> Void = { _ in }

    @State private var active: Int? = nil

    private let handleD: CGFloat = 22
    private let trackH: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width
            let cy = geo.size.height / 2
            let lx = xFor(lower, W)
            let ux = xFor(upper, W)

            ZStack(alignment: .topLeading) {
                Capsule().fill(Color.primary.opacity(0.12))
                    .frame(width: W, height: trackH).position(x: W / 2, y: cy)
                Capsule().fill(Theme.accent)
                    .frame(width: max(0, ux - lx), height: trackH)
                    .position(x: (lx + ux) / 2, y: cy)

                handle(active: active == 0).position(x: lx, y: cy).gesture(drag(0, W))
                handle(active: active == 1).position(x: ux, y: cy).gesture(drag(1, W))
            }
            .coordinateSpace(.named("slider"))
        }
        .frame(height: handleD + 10)
    }

    private func handle(active: Bool) -> some View {
        Circle()
            .fill(.white)
            .frame(width: active ? handleD + 4 : handleD, height: active ? handleD + 4 : handleD)
            .overlay(Circle().strokeBorder(Theme.accent, lineWidth: 3))
            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
    }

    private func xFor(_ v: Double, _ W: CGFloat) -> CGFloat {
        guard maxSec > 0 else { return 0 }
        return CGFloat(v / maxSec) * W
    }

    private func drag(_ handle: Int, _ W: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("slider"))
            .onChanged { v in
                active = handle
                guard maxSec > 0 else { return }
                let t = Double(min(max(v.location.x, 0), W) / W) * maxSec
                if handle == 0 { lower = min(max(0, t), upper - minGap) }
                else            { upper = max(min(maxSec, t), lower + minGap) }
                onScrub(handle == 0 ? lower : upper)
            }
            .onEnded { _ in active = nil; onScrub(nil) }
    }
}

#Preview {
    struct Demo: View {
        @State var a: Double = 600
        @State var b: Double = 1500
        var body: some View {
            GlobalTrimCard(startSec: $a, endSec: $b, maxSec: 7200, previewURL: nil)
                .frame(width: 560).padding()
        }
    }
    return Demo()
}
