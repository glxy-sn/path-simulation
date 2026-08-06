//
//  TrimControl.swift
//  foodcourt
//
//  Created by Shafa Tiara on 04/08/26.
//

import SwiftUI
import AVKit
import AVFoundation

@MainActor
@Observable
final class MultiTrimController {
    struct Entry: Identifiable { let id: URL; let label: String; let player: AVPlayer }

    private(set) var entries: [Entry] = []
    var startSec: Double = 0
    var endSec: Double = 0
    private var observers: [ObjectIdentifier: Any] = [:]

    func setRange(_ s: Double, _ e: Double) {
        startSec = s
        endSec = e
    }

    /// Bangun ulang player kalau daftar url berubah.
    func setCameras(_ cams: [(label: String, url: URL)]) {
        let newURLs = cams.map { $0.url }
        if newURLs == entries.map({ $0.id }) { return }

        for e in entries {
            if let tok = observers[ObjectIdentifier(e.player)] {
                e.player.removeTimeObserver(tok)
            }
        }
        observers.removeAll()

        let interval = CMTime(seconds: 0.12, preferredTimescale: 600)
        entries = cams.map { c in
            let p = AVPlayer(url: c.url)
            p.actionAtItemEnd = .pause
            let tok = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self, weak p] time in
                MainActor.assumeIsolated {
                    guard let self, let p, p.rate != 0 else { return }
                    let t = time.seconds
                    if t >= self.endSec - 0.02 || t < self.startSec - 0.10 {
                        self.seek(p, self.startSec)
                    }
                }
            }
            observers[ObjectIdentifier(p)] = tok
            return Entry(id: c.url, label: c.label, player: p)
        }
        seekAll(startSec)
    }

    /// Menggeser handle: pause semua + tampilkan frame di t.
    func scrub(to t: Double) {
        for e in entries { e.player.pause() }
        seekAll(t)
    }

    private func seekAll(_ t: Double) {
        for e in entries { seek(e.player, t) }
    }

    private func seek(_ p: AVPlayer, _ t: Double) {
        let tol = CMTime(seconds: 0.2, preferredTimescale: 600)
        p.seek(to: CMTime(seconds: max(0, t), preferredTimescale: 600),
               toleranceBefore: tol, toleranceAfter: tol)
    }
}

struct GlobalTrimCard: View {
    @Binding var startSec: Double
    @Binding var endSec: Double
    let maxSec: Double
    var cameras: [(label: String, url: URL)] = []

    @State private var controller = MultiTrimController()

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Rentang Waktu").font(.headline)
                    Text("Satu rentang untuk semua kamera · total \(timecode(maxSec))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Tag(text: timecode(endSec - startSec))
            }

            if cameras.isEmpty {
                placeholder
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: Space.s)],
                          spacing: Space.s) {
                    ForEach(controller.entries) { e in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(e.label).font(.caption.weight(.medium)).lineLimit(1)
                            VideoPlayer(player: e.player)
                                .frame(height: 150)
                                .clipShape(RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                                        .strokeBorder(Theme.hairline)
                                )
                        }
                    }
                }
            }

            Text("Semua preview memutar bagian yang sama (loop di dalam potongan).")
                .font(.caption2).foregroundStyle(.tertiary)

            RangeSlider(lower: $startSec, upper: $endSec, maxSec: maxSec,
                        onScrub: { t in if let t { controller.scrub(to: t) } })

            HStack {
                stat("Mulai", timecode(startSec))
                Spacer()
                stat("Durasi", timecode(endSec - startSec))
                Spacer()
                stat("Selesai", timecode(endSec))
            }
        }
        .card()
        .onAppear {
            controller.setRange(startSec, endSec)
            controller.setCameras(cameras)
        }
        .onChange(of: cameras.map { $0.url }) { _, _ in controller.setCameras(cameras) }
        .onChange(of: startSec) { _, s in controller.setRange(s, endSec) }
        .onChange(of: endSec) { _, e in controller.setRange(startSec, e) }
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                .fill(Color.primary.opacity(0.05)).frame(height: 160)
            VStack(spacing: Space.s) {
                Image(systemName: "film").font(.system(size: 28)).foregroundStyle(.secondary)
                Text("Preview muncul setelah video punya file.").font(.caption).foregroundStyle(.secondary)
            }
        }
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
            GlobalTrimCard(startSec: $a, endSec: $b, maxSec: 7200, cameras: [])
                .frame(width: 620).padding()
        }
    }
    return Demo()
}
