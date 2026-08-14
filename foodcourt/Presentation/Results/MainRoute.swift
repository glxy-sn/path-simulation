//
//  MainRoute.swift
//  foodcourt
//
//  Menyarikan SATU jalur utama dari tumpukan lintasan.
//
//  Idenya: lintasan semua orang ditumpuk jadi peta kepadatan halus. Di tempat
//  yang sering dilewati, tumpukan itu membentuk punggungan terang — persis yang
//  terlihat sebagai garis biru pekat di ringkasan. Punggungan itu dirampingkan
//  jadi garis setebal satu piksel, cabang buntunya dipangkas, ruas-ruasnya
//  disambung, lalu simpulnya dibuang. Sisanya: satu jalur menerus.
//

import AppKit
import CoreGraphics

enum RouteTuning {
    /// Petak peta kepadatan, meter. Kecil = detail, tapi rangkanya mudah putus.
    static let cellM = 0.05
    /// Penghalus peta kepadatan, dalam petak.
    static let heatSmooth = 7.0
    /// Persentil kepadatan; di atas ini dianggap punggungan jalur.
    static let ridgePercentile = 30.0
    /// Berapa kali ujung cabang buntu dipangkas.
    static let pruneRounds = 45
    /// Ruas lebih pendek dari ini (dalam titik) dibuang.
    static let minSegmentPoints = 12
    /// Celah antar ruas sependek ini boleh disambung, meter.
    static let joinMaxM = 2.0
    /// Sambungan ditolak kalau membuat garis berbalik lebih tajam dari ini.
    static let joinMinCos = -0.20
    /// Penghalus akhir, supaya liuk kecil tidak terlihat.
    static let finalSmooth = 7.0
    /// Tahap perangkaian: mulai ketat, lalu makin longgar (celah m, cos minimum).
    /// Yang ketat dulu supaya bentuk jalurnya ditentukan jejak yang benar-benar
    /// bersambung; yang longgar cuma menambal sisa yang terpencil.
    /// Tahap terakhir sengaja tanpa batas: apa pun yang masih tersisa tetap
    /// disambung, supaya tidak ada garis yang tertinggal.
    static let joinLadder: [(Double, Double)] = [(2.0, -0.20), (3.5, -0.40),
                                                 (6.0, -0.80), (.infinity, -1.0)]
}

enum MainRoute {

    /// Rangkai SEMUA lintasan jadi satu garis menerus.
    ///
    /// Tiap lintasan dijarangkan dan dihaluskan dulu, lalu dirangkai serakah:
    /// mulai dari yang terpanjang, terus sambung ke lintasan terdekat yang
    /// belum terpakai — dibalik dulu kalau ujung yang lain lebih dekat.
    /// Hasilnya satu jalur yang melewati semua jejak biru, bukan pilihan
    /// salah satu di antaranya.
    /// Jejak mentah -> jejak yang layak digambar: dijarangkan, dihaluskan kuat
    /// supaya polanya kebentuk (bukan garis gemetar), dan yang terlalu pendek
    /// atau kebanyakan di luar lantai dibuang.
    static func tidyTrails(_ trails: [[CGPoint]], widthM: Double, heightM: Double,
                           floorplan: NSImage?, minLengthM: Double = 0.8,
                           sigma: Double = 3) -> [[CGPoint]] {
        let W = widthM > 0 ? widthM : 10
        let H = heightM > 0 ? heightM : 7.5
        let mask = floorplan.flatMap { FloorPlanMask($0) }
        var pool: [[CGPoint]] = []
        for trail in trails {
            let thinned = stride(from: 0, to: trail.count, by: max(1, trail.count / 90))
                .map { trail[$0] }
            guard thinned.count >= 6 else { continue }
            let clean = smooth(thinned, sigma: sigma)
            guard length(clean, W, H) >= minLengthM else { continue }
            if let mask {
                let inside = clean.filter { mask.contains($0) }.count
                guard Double(inside) / Double(clean.count) >= 0.5 else { continue }
            }
            pool.append(clean)
        }
        pool.sort { length($0, W, H) > length($1, W, H) }
        return pool
    }

    static func chainAll(_ trails: [[CGPoint]], widthM: Double, heightM: Double,
                         floorplan: NSImage?, minLengthM: Double = 0.8,
                         sigma: Double = 3) -> [CGPoint] {
        let W = widthM > 0 ? widthM : 10
        let H = heightM > 0 ? heightM : 7.5

        var pool = tidyTrails(trails, widthM: W, heightM: H, floorplan: floorplan,
                              minLengthM: minLengthM, sigma: sigma)
        guard !pool.isEmpty else { return [] }
        let route = growOne(&pool, W: W, H: H)
        // haluskan sambungannya, lalu buang bagian yang menyilang dirinya sendiri
        return removeLoops(smooth(route, sigma: RouteTuning.finalSmooth))
    }

    /// Ambil ruas terpanjang yang tersisa di `pool`, lalu tumbuhkan dari kedua
    /// ujungnya selama masih ada ruas searah yang cukup dekat. Yang terpakai
    /// dibuang dari `pool`, jadi sisanya bisa dirangkai jadi garis berikutnya.
    private static func growOne(_ pool: inout [[CGPoint]], W: Double, H: Double,
                                ladder: [(Double, Double)] = RouteTuning.joinLadder) -> [CGPoint] {
        pool.sort { length($0, W, H) > length($1, W, H) }

        // arah satuan dari a ke b, dihitung dalam meter
        func heading(_ a: CGPoint, _ b: CGPoint) -> (Double, Double) {
            let dx = Double(b.x - a.x) * W, dy = Double(b.y - a.y) * H
            let m = hypot(dx, dy)
            return m < 1e-9 ? (0, 0) : (dx / m, dy / m)
        }

        var route = pool.removeFirst()

        /// Cari lintasan terdekat yang boleh disambung ke satu ujung jalur.
        /// `atTail` menentukan ujung mana yang sedang ditumbuhkan.
        func pick(atTail: Bool, maxGap: Double, minCos: Double)
        -> (index: Int, flip: Bool, gap: Double)? {
            let end = atTail ? route[route.count - 1] : route[0]
            let back = min(4, route.count - 1)
            // arah keluar dari ujung yang sedang ditumbuhkan
            let exit = atTail ? heading(route[route.count - 1 - back], end)
                              : heading(route[back], end)
            var best: (index: Int, flip: Bool, gap: Double)?
            for (i, other) in pool.enumerated() {
                for flip in [false, true] {
                    let seq = flip ? Array(other.reversed()) : other
                    let gap = hypot(Double(end.x - seq[0].x) * W,
                                    Double(end.y - seq[0].y) * H)
                    guard gap <= maxGap, best == nil || gap < best!.gap else { continue }
                    // hanya sambung ke ruas yang searah dengan ujung sekarang —
                    // ini yang mencegah garis berbalik dan menyimpul
                    let k = min(4, seq.count - 1)
                    let entry = heading(seq[0], seq[k])
                    guard exit.0 * entry.0 + exit.1 * entry.1 >= minCos else { continue }
                    best = (i, flip, gap)
                }
            }
            return best
        }

        // Tumbuhkan dari kedua ujung. Kalau tidak ada lagi yang lolos, syaratnya
        // dilonggarkan bertahap supaya jejak yang agak jauh tetap ikut terangkai.
        for (maxGap, minCos) in ladder {
            var grew = true
            while grew, !pool.isEmpty {
                grew = false
                for atTail in [true, false] {
                    guard let hit = pick(atTail: atTail, maxGap: maxGap, minCos: minCos)
                    else { continue }
                    var next = pool.remove(at: hit.index)
                    if hit.flip { next.reverse() }
                    if atTail {
                        route += next
                    } else {
                        route.insert(contentsOf: next.reversed(), at: 0)
                    }
                    grew = true
                }
            }
        }
        return route
    }

    /// Titik ternormalisasi 0...1. Kembalikan satu jalur, atau kosong kalau
    /// datanya tidak cukup membentuk punggungan.
    static func extract(points: [CGPoint], widthM: Double, heightM: Double,
                        floorplan: NSImage?) -> [CGPoint] {
        let W = widthM > 0 ? widthM : 10
        let H = heightM > 0 ? heightM : 7.5
        let cols = Int(ceil(W / RouteTuning.cellM))
        let rows = Int(ceil(H / RouteTuning.cellM))
        guard points.count > 200, cols > 8, rows > 8 else { return [] }

        let mask = floorplan.flatMap { FloorPlanMask($0) }

        // 1. tumpuk jadi peta kepadatan, lalu haluskan
        var heat = [Double](repeating: 0, count: cols * rows)
        for p in points {
            let c = min(cols - 1, max(0, Int(Double(p.x) * Double(cols))))
            let r = min(rows - 1, max(0, Int(Double(p.y) * Double(rows))))
            heat[r * cols + c] += 1
        }
        heat = blur(heat, cols: cols, rows: rows, sigma: RouteTuning.heatSmooth)

        // 2. ambil punggungannya
        let hot = heat.filter { $0 > 0 }.sorted()
        guard hot.count > 50 else { return [] }
        let cut = hot[min(hot.count - 1, Int(Double(hot.count) * RouteTuning.ridgePercentile / 100))]
        var ridge = [Bool](repeating: false, count: cols * rows)
        for r in 0..<rows {
            for c in 0..<cols where heat[r * cols + c] >= cut {
                let p = CGPoint(x: (Double(c) + 0.5) / Double(cols),
                                y: (Double(r) + 0.5) / Double(rows))
                ridge[r * cols + c] = mask?.contains(p) ?? true
            }
        }

        // 3. rampingkan jadi garis, pangkas cabang buntu
        var bone = thin(ridge, cols: cols, rows: rows)
        bone = prune(bone, cols: cols, rows: rows, rounds: RouteTuning.pruneRounds)

        // 4. pecah jadi ruas, saring ke lantai, sambung, buang simpul
        var segments = segmentise(bone, cols: cols, rows: rows).map { chain in
            chain.map { CGPoint(x: CGFloat((Double($0.0) + 0.5) / Double(cols)),
                                y: CGFloat((Double($0.1) + 0.5) / Double(rows))) }
        }
        if let mask {
            segments = segments.filter { seg in
                let inside = seg.filter { mask.contains($0) }.count
                return Double(inside) / Double(seg.count) >= 0.7
            }
        }
        guard !segments.isEmpty else { return [] }
        segments = segments.map { smooth($0, sigma: 4) }
        segments.sort { length($0, W, H) > length($1, W, H) }

        guard var route = join(segments, W: W, H: H).first else { return [] }
        route = removeLoops(route)
        guard route.count > 8, length(route, W, H) >= 3 else { return [] }
        return smooth(route, sigma: RouteTuning.finalSmooth)
    }

    /// Dorong garis keluar dari perabot.
    ///
    /// Titik yang jatuh di atas meja/konter tidak dibuang — jalurnya tetap ada,
    /// tapi digeser ke petak lantai terdekat, jadi garisnya menempel di tepi
    /// perabot itu alih-alih memotongnya.
    static func snapToFloor(_ lines: [[CGPoint]], widthM: Double, heightM: Double,
                            floorplan: NSImage?, maxShiftM: Double = 1.5) -> [[CGPoint]] {
        let W = widthM > 0 ? widthM : 10
        guard let mask = floorplan.flatMap({
            FloorPlanMask($0, openM: 0.8, widthM: W)
        }) else { return lines }
        let H = heightM > 0 ? heightM : 7.5
        let step = 0.05
        let maxRing = Int(ceil(maxShiftM / step))

        func nearestFloor(_ p: CGPoint) -> CGPoint? {
            for ring in 1...maxRing {
                let radius = Double(ring) * step
                var best: (CGPoint, Double)?
                let samples = max(8, ring * 4)
                for k in 0..<samples {
                    let angle = 2 * Double.pi * Double(k) / Double(samples)
                    let q = CGPoint(x: p.x + CGFloat(cos(angle) * radius / W),
                                    y: p.y + CGFloat(sin(angle) * radius / H))
                    guard q.x >= 0, q.x <= 1, q.y >= 0, q.y <= 1, mask.contains(q) else { continue }
                    let d = hypot(Double(q.x - p.x) * W, Double(q.y - p.y) * H)
                    if best == nil || d < best!.1 { best = (q, d) }
                }
                if let hit = best { return hit.0 }
            }
            return nil
        }

        return lines.map { line in
            let moved = line.map { p -> CGPoint in
                mask.contains(p) ? p : (nearestFloor(p) ?? p)
            }
            // digeser titik per titik bikin garisnya bergerigi di tepi perabot,
            // jadi dihaluskan lebih kuat sesudahnya
            return smooth(moved, sigma: 7)
        }
    }

    /// Buang bagian garis yang menimpa garis lain.
    ///
    /// Garis diurut dari yang terpanjang; yang berikutnya cuma diambil
    /// potongan yang belum ditempati — jadi di tiap tempat cuma ada satu garis,
    /// tanpa kehilangan bagian yang memang cuma dia yang punya.
    static func dedupe(_ lines: [[CGPoint]], widthM: Double, heightM: Double,
                       tolM: Double = 0.25, minRun: Int = 8,
                       minLengthM: Double = 0) -> [[CGPoint]] {
        let W = widthM > 0 ? widthM : 10
        let H = heightM > 0 ? heightM : 7.5
        let sorted = lines.filter { $0.count >= 2 }.sorted {
            length($0, W, H) > length($1, W, H)
        }
        var kept: [[CGPoint]] = []

        func ditempati(_ p: CGPoint) -> Bool {
            for line in kept {
                for q in line {
                    if hypot(Double(p.x - q.x) * W, Double(p.y - q.y) * H) <= tolM {
                        return true
                    }
                }
            }
            return false
        }

        for line in sorted {
            var run: [CGPoint] = []
            for p in line {
                if ditempati(p) {
                    if run.count >= minRun { kept.append(run) }
                    run = []
                } else {
                    run.append(p)
                }
            }
            if run.count >= minRun { kept.append(run) }
        }
        // sisa potongan yang terlalu pendek dibuang: itu serpihan, bukan jalur
        return kept.filter { length($0, W, H) >= minLengthM }
    }

    /// Gabungkan potongan-potongan jadi SATU garis. Ruas terpanjang jadi
    /// pangkalnya, lalu ditumbuhkan dari kedua ujung: mula-mula hanya ke
    /// tetangga dekat yang searah, baru dilonggarkan sedikit demi sedikit.
    /// Yang tetap tidak nyambung wajar ditinggal, supaya hasilnya tetap rapi.
    static func unify(_ segments: [[CGPoint]], widthM: Double, heightM: Double) -> [CGPoint] {
        let W = widthM > 0 ? widthM : 10
        let H = heightM > 0 ? heightM : 7.5
        var pool = segments.filter { $0.count >= 4 }
        guard !pool.isEmpty else { return [] }
        // Tangga dilanjutkan sampai longgar, supaya seluruh potongan ikut
        // terangkai — yang dicari satu rute keliling, bukan satu garis pendek.
        let ladder: [(Double, Double)] = [(0.8, 0.30), (1.5, 0.0),
                                          (2.5, -0.30), (4.0, -0.60)]
        var route = growOne(&pool, W: W, H: H, ladder: ladder)
        route = removeLoops(smooth(route, sigma: RouteTuning.finalSmooth))

        // Kalau kedua ujungnya berdekatan, rutenya ditutup jadi lingkaran penuh.
        if let head = route.first, let tail = route.last,
           hypot(Double(head.x - tail.x) * W, Double(head.y - tail.y) * H) <= 3.0 {
            route.append(head)
            route = smooth(route, sigma: 3)
        }
        return route
    }

    /// Cincin mengelilingi tiap perabot (meja/konter) yang dikitari orang.
    ///
    /// Cabang yang mentok di kursi tidak dipangkas dan tidak dibiarkan buntu,
    /// tapi diteruskan jadi lingkaran penuh: rongga bukan-lantai di dalam
    /// ruangan dicari, tepinya diambil, lalu digeser keluar sejauh `offsetM`
    /// dan diurutkan melingkar. Hasilnya jalur tertutup yang memutari meja.
    static func ringsAroundTables(points: [CGPoint], widthM: Double, heightM: Double,
                                  floorplan: NSImage?, offsetM: Double = 0.45,
                                  minAreaM2: Double = 0.6,
                                  nearM: Double = 1.2,
                                  supportM: Double = 0.8) -> [[CGPoint]] {
        let W = widthM > 0 ? widthM : 10
        let H = heightM > 0 ? heightM : 7.5
        guard let mask = floorplan.flatMap({ FloorPlanMask($0) }), !points.isEmpty
        else { return [] }

        let cols = Int(ceil(W / 0.05)), rows = Int(ceil(H / 0.05))
        let cellArea = (W / Double(cols)) * (H / Double(rows))

        // petak yang pernah dilewati, dipakai untuk memilih perabot mana saja
        var visited = [Bool](repeating: false, count: cols * rows)
        for p in points {
            let c = min(cols - 1, max(0, Int(Double(p.x) * Double(cols))))
            let r = min(rows - 1, max(0, Int(Double(p.y) * Double(rows))))
            visited[r * cols + c] = true
        }

        func isFloor(_ c: Int, _ r: Int) -> Bool {
            mask.contains(CGPoint(x: (Double(c) + 0.5) / Double(cols),
                                  y: (Double(r) + 0.5) / Double(rows)))
        }

        // rongga bukan-lantai, 4-arah; yang menyentuh tepi gambar dibuang
        // (itu dinding luar, bukan meja)
        var seen = [Bool](repeating: false, count: cols * rows)
        var rings: [[CGPoint]] = []
        for r0 in 0..<rows {
            for c0 in 0..<cols where !seen[r0 * cols + c0] && !isFloor(c0, r0) {
                var stack = [(c0, r0)], cells: [(Int, Int)] = []
                var touchesEdge = false
                seen[r0 * cols + c0] = true
                while let (c, r) = stack.popLast() {
                    cells.append((c, r))
                    if c == 0 || r == 0 || c == cols - 1 || r == rows - 1 { touchesEdge = true }
                    for (dc, dr) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                        let nc = c + dc, nr = r + dr
                        guard nc >= 0, nc < cols, nr >= 0, nr < rows else { continue }
                        let idx = nr * cols + nc
                        if !seen[idx] && !isFloor(nc, nr) { seen[idx] = true; stack.append((nc, nr)) }
                    }
                }
                guard !touchesEdge,
                      Double(cells.count) * cellArea >= minAreaM2 else { continue }

                // hanya perabot yang memang dikitari orang
                let nearCells = Int(ceil(nearM / 0.05))
                let dilihat = cells.contains { (c, r) in
                    for dr in -nearCells...nearCells {
                        for dc in -nearCells...nearCells {
                            let nc = c + dc, nr = r + dr
                            guard nc >= 0, nc < cols, nr >= 0, nr < rows else { continue }
                            if visited[nr * cols + nc] { return true }
                        }
                    }
                    return false
                }
                guard dilihat else { continue }

                // tepi rongga -> digeser keluar dari pusatnya -> diurutkan melingkar
                let cx = Double(cells.map { $0.0 }.reduce(0, +)) / Double(cells.count)
                let cy = Double(cells.map { $0.1 }.reduce(0, +)) / Double(cells.count)
                var edge: [(Double, Double)] = []
                for (c, r) in cells {
                    var border = false
                    for (dc, dr) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                        let nc = c + dc, nr = r + dr
                        if nc < 0 || nc >= cols || nr < 0 || nr >= rows || isFloor(nc, nr) {
                            border = true; break
                        }
                    }
                    guard border else { continue }
                    let dx = Double(c) - cx, dy = Double(r) - cy
                    let m = (dx * dx + dy * dy).squareRoot()
                    guard m > 1e-9 else { continue }
                    edge.append((Double(c) + dx / m * offsetM / 0.05,
                                 Double(r) + dy / m * offsetM / 0.05))
                }
                guard edge.count >= 12 else { continue }
                edge.sort { atan2($0.1 - cy, $0.0 - cx) < atan2($1.1 - cy, $1.0 - cx) }

                let ring = edge.map { CGPoint(x: CGFloat(($0.0 + 0.5) / Double(cols)),
                                              y: CGFloat(($0.1 + 0.5) / Double(rows))) }

                // Hanya bagian cincin yang benar-benar ada jejaknya yang dipakai.
                // Sisi meja yang tidak pernah dilewati siapa pun tidak digambar,
                // jadi yang tampil busur-busur nyata, bukan lingkaran karangan.
                let reach = Int(ceil(supportM / 0.05))
                func didukung(_ p: CGPoint) -> Bool {
                    let c = Int(Double(p.x) * Double(cols)), r = Int(Double(p.y) * Double(rows))
                    for dr in -reach...reach {
                        for dc in -reach...reach {
                            let nc = c + dc, nr = r + dr
                            guard nc >= 0, nc < cols, nr >= 0, nr < rows else { continue }
                            if visited[nr * cols + nc] { return true }
                        }
                    }
                    return false
                }
                var run: [CGPoint] = []
                for p in ring {
                    if didukung(p) {
                        run.append(p)
                    } else {
                        if run.count >= 8 { rings.append(smooth(run, sigma: 6)) }
                        run = []
                    }
                }
                if run.count >= 8 { rings.append(smooth(run, sigma: 6)) }
            }
        }
        return rings
    }

    /// Jalur keliling: rangka dari seluruh jejak yang dibatasi ke lantai, lalu
    /// hanya rangka yang SATU kesatuan yang diambil. Karena lantainya melubang
    /// di posisi meja, rangka itu otomatis melingkari meja alih-alih memotongnya
    /// — jadi sambungannya mengikuti ruang jalan, bukan lompat lurus.
    static func loopAroundTables(points: [CGPoint], widthM: Double, heightM: Double,
                                 floorplan: NSImage?,
                                 percentile: Double = 10,
                                 heatSigma: Double = RouteTuning.heatSmooth,
                                 pruneRounds: Int = 12) -> [[CGPoint]] {
        let W = widthM > 0 ? widthM : 10
        let H = heightM > 0 ? heightM : 7.5
        let cols = Int(ceil(W / RouteTuning.cellM))
        let rows = Int(ceil(H / RouteTuning.cellM))
        guard points.count > 200, cols > 8, rows > 8 else { return [] }

        let mask = floorplan.flatMap { FloorPlanMask($0) }

        var heat = [Double](repeating: 0, count: cols * rows)
        for p in points {
            let c = min(cols - 1, max(0, Int(Double(p.x) * Double(cols))))
            let r = min(rows - 1, max(0, Int(Double(p.y) * Double(rows))))
            heat[r * cols + c] += 1
        }
        heat = blur(heat, cols: cols, rows: rows, sigma: heatSigma)

        let hot = heat.filter { $0 > 0 }.sorted()
        guard hot.count > 50 else { return [] }
        let cut = hot[min(hot.count - 1, Int(Double(hot.count) * percentile / 100))]
        var area = [Bool](repeating: false, count: cols * rows)
        for r in 0..<rows {
            for c in 0..<cols where heat[r * cols + c] >= cut {
                let p = CGPoint(x: (Double(c) + 0.5) / Double(cols),
                                y: (Double(r) + 0.5) / Double(rows))
                area[r * cols + c] = mask?.contains(p) ?? true
            }
        }

        // ambil hamparan terbesar dulu, baru dirampingkan: hasilnya satu rangka
        // menerus yang mengelilingi lubang-lubang (meja) di dalamnya
        area = largestBlob(area, cols: cols, rows: rows)
        var bone = thin(area, cols: cols, rows: rows)
        if pruneRounds > 0 { bone = prune(bone, cols: cols, rows: rows, rounds: pruneRounds) }

        var segments = segmentise(bone, cols: cols, rows: rows).map { chain in
            chain.map { CGPoint(x: CGFloat((Double($0.0) + 0.5) / Double(cols)),
                                y: CGFloat((Double($0.1) + 0.5) / Double(rows))) }
        }
        segments = segments.filter { $0.count >= 4 }
        guard !segments.isEmpty else { return [] }
        // Sambungan yang wajar: beloknya paling tajam 90 derajat (cos >= 0) dan
        // celahnya paling jauh 1.5 m. Lebih tajam dari itu garisnya berbalik,
        // lebih jauh dari itu sambungannya jadi lompatan menyeberang ruangan.
        segments.sort { length($0, W, H) > length($1, W, H) }
        return join(segments, W: W, H: H, maxGapM: 1.5, minCos: 0.0)
            .map { smooth($0, sigma: 5) }
    }

    /// Hamparan tersambung terbesar (8-arah). Sisanya dibuang.
    private static func largestBlob(_ mask: [Bool], cols: Int, rows: Int) -> [Bool] {
        var seen = [Bool](repeating: false, count: mask.count)
        var best: [Int] = []
        for start in mask.indices where mask[start] && !seen[start] {
            var stack = [start], cells: [Int] = []
            seen[start] = true
            while let cur = stack.popLast() {
                cells.append(cur)
                let r = cur / cols, c = cur % cols
                for dr in -1...1 {
                    for dc in -1...1 where !(dr == 0 && dc == 0) {
                        let nr = r + dr, nc = c + dc
                        guard nr >= 0, nr < rows, nc >= 0, nc < cols else { continue }
                        let idx = nr * cols + nc
                        if mask[idx] && !seen[idx] { seen[idx] = true; stack.append(idx) }
                    }
                }
            }
            if cells.count > best.count { best = cells }
        }
        var out = [Bool](repeating: false, count: mask.count)
        for cell in best { out[cell] = true }
        return out
    }

    /// Pola jalur: punggungan dari tumpukan jejak, dirampingkan jadi garis,
    /// dibatasi ke lantai saja, lalu ruas-ruasnya disambung yang searah.
    /// Beda dengan `extract` yang memaksa satu garis — di sini semua ruas
    /// dikembalikan, jadi polanya utuh tapi tetap bersih.
    static func network(points: [CGPoint], widthM: Double, heightM: Double,
                        floorplan: NSImage?, minLengthM: Double = 1.5,
                        pruneRounds: Int = RouteTuning.pruneRounds,
                        percentile: Double = RouteTuning.ridgePercentile,
                        heatSigma: Double = RouteTuning.heatSmooth) -> [[CGPoint]] {
        let W = widthM > 0 ? widthM : 10
        let H = heightM > 0 ? heightM : 7.5
        let cols = Int(ceil(W / RouteTuning.cellM))
        let rows = Int(ceil(H / RouteTuning.cellM))
        guard points.count > 200, cols > 8, rows > 8 else { return [] }

        let mask = floorplan.flatMap { FloorPlanMask($0) }

        // 1. peta kepadatan yang dihaluskan
        var heat = [Double](repeating: 0, count: cols * rows)
        for p in points {
            let c = min(cols - 1, max(0, Int(Double(p.x) * Double(cols))))
            let r = min(rows - 1, max(0, Int(Double(p.y) * Double(rows))))
            heat[r * cols + c] += 1
        }
        heat = blur(heat, cols: cols, rows: rows, sigma: heatSigma)

        // 2. ambil bagian terpadat — dan hanya yang jatuh di lantai
        let hot = heat.filter { $0 > 0 }.sorted()
        guard hot.count > 50 else { return [] }
        let cut = hot[min(hot.count - 1, Int(Double(hot.count) * percentile / 100))]
        var ridge = [Bool](repeating: false, count: cols * rows)
        for r in 0..<rows {
            for c in 0..<cols where heat[r * cols + c] >= cut {
                let p = CGPoint(x: (Double(c) + 0.5) / Double(cols),
                                y: (Double(r) + 0.5) / Double(rows))
                ridge[r * cols + c] = mask?.contains(p) ?? true
            }
        }

        // 3. rampingkan jadi garis setebal satu petak, pangkas cabang buntu
        var bone = thin(ridge, cols: cols, rows: rows)
        if pruneRounds > 0 {
            bone = prune(bone, cols: cols, rows: rows, rounds: pruneRounds)
        }

        // 4. pecah di persimpangan, saring, haluskan, lalu sambung yang searah
        var segments = segmentise(bone, cols: cols, rows: rows).map { chain in
            chain.map { CGPoint(x: CGFloat((Double($0.0) + 0.5) / Double(cols)),
                                y: CGFloat((Double($0.1) + 0.5) / Double(rows))) }
        }
        if let mask {
            segments = segments.filter { seg in
                let inside = seg.filter { mask.contains($0) }.count
                return Double(inside) / Double(seg.count) >= 0.9
            }
        }
        guard !segments.isEmpty else { return [] }
        segments = segments.map { smooth($0, sigma: 4) }
        segments.sort { length($0, W, H) > length($1, W, H) }

        return join(segments, W: W, H: H)
            .map { removeLoops(smooth($0, sigma: RouteTuning.finalSmooth)) }
            .filter { $0.count > 1 && length($0, W, H) >= minLengthM }
    }

    /// Pola akhir yang digambar: punggungan dari seluruh jejak, lalu ruas-ruasnya
    /// dirangkai jadi beberapa garis panjang saja — bukan tumpukan potongan.
    static func pattern(points: [CGPoint], widthM: Double, heightM: Double,
                        floorplan: NSImage?, maxLines: Int = 3,
                        minLengthM: Double = 2.0,
                        pruneRounds: Int = RouteTuning.pruneRounds,
                        percentile: Double = RouteTuning.ridgePercentile,
                        heatSigma: Double = RouteTuning.heatSmooth) -> [[CGPoint]] {
        let W = widthM > 0 ? widthM : 10
        let H = heightM > 0 ? heightM : 7.5
        var pool = network(points: points, widthM: W, heightM: H,
                           floorplan: floorplan, minLengthM: minLengthM,
                           pruneRounds: pruneRounds, percentile: percentile,
                           heatSigma: heatSigma)
        guard !pool.isEmpty else { return [] }

        var lines: [[CGPoint]] = []
        while !pool.isEmpty, lines.count < maxLines {
            let route = removeLoops(smooth(growOne(&pool, W: W, H: H),
                                           sigma: RouteTuning.finalSmooth))
            if route.count > 1, length(route, W, H) >= minLengthM { lines.append(route) }
        }
        return lines
    }

    // MARK: - langkah-langkah

    private static func length(_ path: [CGPoint], _ W: Double, _ H: Double) -> Double {
        guard path.count > 1 else { return 0 }
        var total = 0.0
        for i in 1..<path.count {
            let dx = Double(path[i].x - path[i - 1].x) * W
            let dy = Double(path[i].y - path[i - 1].y) * H
            total += (dx * dx + dy * dy).squareRoot()
        }
        return total
    }

    /// Gauss dua arah, dipisah jadi mendatar lalu menegak.
    private static func blur(_ field: [Double], cols: Int, rows: Int, sigma: Double) -> [Double] {
        guard sigma > 0 else { return field }
        let radius = max(1, Int(sigma * 2.5))
        var kernel: [Double] = []
        for i in -radius...radius { kernel.append(exp(-Double(i * i) / (2 * sigma * sigma))) }
        let norm = kernel.reduce(0, +)
        var pass = [Double](repeating: 0, count: field.count)
        for r in 0..<rows {
            for c in 0..<cols {
                var sum = 0.0
                for (k, w) in kernel.enumerated() {
                    sum += field[r * cols + min(cols - 1, max(0, c + k - radius))] * w
                }
                pass[r * cols + c] = sum / norm
            }
        }
        var out = [Double](repeating: 0, count: field.count)
        for c in 0..<cols {
            for r in 0..<rows {
                var sum = 0.0
                for (k, w) in kernel.enumerated() {
                    sum += pass[min(rows - 1, max(0, r + k - radius)) * cols + c] * w
                }
                out[r * cols + c] = sum / norm
            }
        }
        return out
    }

    /// Zhang-Suen: kikis tepi berulang sampai tinggal garis setebal satu piksel.
    private static func thin(_ mask: [Bool], cols: Int, rows: Int) -> [Bool] {
        var img = mask
        func at(_ r: Int, _ c: Int) -> Int {
            (r >= 0 && r < rows && c >= 0 && c < cols && img[r * cols + c]) ? 1 : 0
        }
        var rounds = 0
        var changed = true
        while changed && rounds < 200 {
            changed = false
            rounds += 1
            for pass in 0..<2 {
                var remove: [Int] = []
                for r in 1..<(rows - 1) {
                    for c in 1..<(cols - 1) where img[r * cols + c] {
                        let p2 = at(r - 1, c), p3 = at(r - 1, c + 1), p4 = at(r, c + 1)
                        let p5 = at(r + 1, c + 1), p6 = at(r + 1, c), p7 = at(r + 1, c - 1)
                        let p8 = at(r, c - 1), p9 = at(r - 1, c - 1)
                        let n = p2 + p3 + p4 + p5 + p6 + p7 + p8 + p9
                        guard n >= 2, n <= 6 else { continue }
                        let seq = [p2, p3, p4, p5, p6, p7, p8, p9, p2]
                        var transitions = 0
                        for i in 0..<8 where seq[i] == 0 && seq[i + 1] == 1 { transitions += 1 }
                        guard transitions == 1 else { continue }
                        if pass == 0 {
                            guard p2 * p4 * p6 == 0, p4 * p6 * p8 == 0 else { continue }
                        } else {
                            guard p2 * p4 * p8 == 0, p2 * p6 * p8 == 0 else { continue }
                        }
                        remove.append(r * cols + c)
                    }
                }
                if !remove.isEmpty {
                    changed = true
                    for idx in remove { img[idx] = false }
                }
            }
        }
        return img
    }

    private static func neighbourCount(_ img: [Bool], _ r: Int, _ c: Int,
                                       _ cols: Int, _ rows: Int) -> Int {
        var n = 0
        for dr in -1...1 {
            for dc in -1...1 where !(dr == 0 && dc == 0) {
                let nr = r + dr, nc = c + dc
                if nr >= 0, nr < rows, nc >= 0, nc < cols, img[nr * cols + nc] { n += 1 }
            }
        }
        return n
    }

    /// Buang ujung cabang berulang kali, sehingga tinggal koridor yang
    /// benar-benar menghubungkan dua tempat.
    private static func prune(_ mask: [Bool], cols: Int, rows: Int, rounds: Int) -> [Bool] {
        var img = mask
        for _ in 0..<rounds {
            var ends: [Int] = []
            for r in 0..<rows {
                for c in 0..<cols where img[r * cols + c] {
                    if neighbourCount(img, r, c, cols, rows) <= 1 { ends.append(r * cols + c) }
                }
            }
            if ends.isEmpty { break }
            for idx in ends { img[idx] = false }
        }
        return img
    }

    /// Pecah rangka jadi ruas menerus, memutus di simpang dan ujung.
    private static func segmentise(_ mask: [Bool], cols: Int, rows: Int) -> [[(Int, Int)]] {
        var neighbours: [Int: [Int]] = [:]
        for r in 0..<rows {
            for c in 0..<cols where mask[r * cols + c] {
                var list: [Int] = []
                for dr in -1...1 {
                    for dc in -1...1 where !(dr == 0 && dc == 0) {
                        let nr = r + dr, nc = c + dc
                        if nr >= 0, nr < rows, nc >= 0, nc < cols, mask[nr * cols + nc] {
                            list.append(nr * cols + nc)
                        }
                    }
                }
                neighbours[r * cols + c] = list
            }
        }
        let nodes = Set(neighbours.keys.filter { (neighbours[$0]?.count ?? 0) != 2 })
        var used = Set<Int64>()
        func key(_ a: Int, _ b: Int) -> Int64 { Int64(min(a, b)) << 32 | Int64(max(a, b)) }

        var segments: [[(Int, Int)]] = []
        for start in nodes {
            for first in neighbours[start] ?? [] where !used.contains(key(start, first)) {
                var chain = [start, first]
                used.insert(key(start, first))
                var prev = start, cur = first
                while !nodes.contains(cur) {
                    guard let next = (neighbours[cur] ?? []).first(where: { $0 != prev }) else { break }
                    used.insert(key(cur, next))
                    prev = cur; cur = next
                    chain.append(cur)
                }
                if chain.count >= RouteTuning.minSegmentPoints {
                    segments.append(chain.map { ($0 % cols, $0 / cols) })
                }
            }
        }
        return segments
    }

    private static func smooth(_ path: [CGPoint], sigma: Double) -> [CGPoint] {
        guard path.count > 6, sigma > 0 else { return path }
        let radius = max(1, Int(sigma * 2.5))
        var kernel: [Double] = []
        for i in -radius...radius { kernel.append(exp(-Double(i * i) / (2 * sigma * sigma))) }
        let norm = kernel.reduce(0, +)
        return path.indices.map { index in
            var sx = 0.0, sy = 0.0
            for (k, w) in kernel.enumerated() {
                let j = min(path.count - 1, max(0, index + k - radius))
                sx += Double(path[j].x) * w
                sy += Double(path[j].y) * w
            }
            return CGPoint(x: sx / norm, y: sy / norm)
        }
    }

    /// Sambung ruas yang ujungnya berdekatan DAN searah.
    ///
    /// Syarat searah itu yang mencegah simpul: dua ruas yang tersambung dengan
    /// arah berlawanan membuat garis berbalik menimpa dirinya sendiri.
    private static func join(_ segments: [[CGPoint]], W: Double, H: Double,
                             maxGapM: Double = RouteTuning.joinMaxM,
                             minCos: Double = RouteTuning.joinMinCos) -> [[CGPoint]] {
        var pool = segments
        var result: [[CGPoint]] = []
        while !pool.isEmpty {
            var cur = pool.removeFirst()
            var merged = true
            while merged {
                merged = false
                var best: (score: Double, index: Int, atTail: Bool, fromHead: Bool)?
                for (i, other) in pool.enumerated() {
                    let step = min(5, cur.count - 1, other.count - 1)
                    guard step > 0 else { continue }
                    for atTail in [true, false] {
                        for fromHead in [true, false] {
                            let a = atTail ? cur[cur.count - 1] : cur[0]
                            let b = fromHead ? other[0] : other[other.count - 1]
                            let gap = hypot(Double(a.x - b.x) * W, Double(a.y - b.y) * H)
                            guard gap <= maxGapM else { continue }

                            let outRaw = atTail
                                ? CGPoint(x: cur[cur.count - 1].x - cur[cur.count - 1 - step].x,
                                          y: cur[cur.count - 1].y - cur[cur.count - 1 - step].y)
                                : CGPoint(x: cur[0].x - cur[step].x, y: cur[0].y - cur[step].y)
                            let inRaw = fromHead
                                ? CGPoint(x: other[step].x - other[0].x,
                                          y: other[step].y - other[0].y)
                                : CGPoint(x: other[other.count - 1 - step].x - other[other.count - 1].x,
                                          y: other[other.count - 1 - step].y - other[other.count - 1].y)
                            let ol = hypot(Double(outRaw.x) * W, Double(outRaw.y) * H)
                            let il = hypot(Double(inRaw.x) * W, Double(inRaw.y) * H)
                            guard ol > 1e-9, il > 1e-9 else { continue }
                            let cos = (Double(outRaw.x) * W * Double(inRaw.x) * W
                                     + Double(outRaw.y) * H * Double(inRaw.y) * H) / (ol * il)
                            guard cos >= minCos else { continue }
                            let score = cos - gap / max(maxGapM, 1e-9)
                            if best == nil || score > best!.score {
                                best = (score, i, atTail, fromHead)
                            }
                        }
                    }
                }
                if let pick = best {
                    let other = pool.remove(at: pick.index)
                    let piece = pick.fromHead ? other : Array(other.reversed())
                    cur = pick.atTail ? cur + piece : Array(cur.reversed()) + piece
                    merged = true
                }
            }
            result.append(cur)
        }
        result.sort { length($0, W, H) > length($1, W, H) }
        return result
    }

    /// Kalau garis memotong dirinya sendiri, bagian yang melingkar dipotong.
    private static func removeLoops(_ path: [CGPoint], minGap: Int = 14) -> [CGPoint] {
        var work = path
        var changed = true
        var guardCount = 0
        while changed && work.count > minGap + 2 && guardCount < 200 {
            changed = false
            guardCount += 1
            outer: for i in 0..<(work.count - 1) {
                for j in stride(from: i + minGap, to: work.count - 1, by: 1) {
                    if let hit = crossing(work[i], work[i + 1], work[j], work[j + 1]) {
                        work = Array(work[0...i]) + [hit] + Array(work[(j + 1)...])
                        changed = true
                        break outer
                    }
                }
            }
        }
        return work
    }

    private static func crossing(_ a: CGPoint, _ b: CGPoint,
                                 _ c: CGPoint, _ d: CGPoint) -> CGPoint? {
        let r = CGPoint(x: b.x - a.x, y: b.y - a.y)
        let s = CGPoint(x: d.x - c.x, y: d.y - c.y)
        let den = r.x * s.y - r.y * s.x
        guard abs(den) > 1e-12 else { return nil }
        let t = ((c.x - a.x) * s.y - (c.y - a.y) * s.x) / den
        let v = ((c.x - a.x) * r.y - (c.y - a.y) * r.x) / den
        guard t >= 0, t <= 1, v >= 0, v <= 1 else { return nil }
        return CGPoint(x: a.x + r.x * t, y: a.y + r.y * t)
    }
}

// MARK: - Masker lantai

/// Hamparan lantai dari gambar denah.
///
/// Ambang kecerahan saja tidak cukup: bagian dalam konter dan ruang di luar
/// dinding juga putih. Karena masing-masing terkurung garisnya sendiri, yang
/// dipakai hanya hamparan putih TERBESAR yang menyambung.
struct FloorPlanMask {
    private let cols: Int
    private let rows: Int
    private let floor: [Bool]

    /// `openM` > 0: lorong yang lebih sempit dari itu ikut dibuang. Berguna
    /// untuk celah tipis antara konter dan dinding — di denah dia putih, tapi
    /// tidak mungkin jadi jalur orang.
    init?(_ image: NSImage, resolution: Int = 220, openM: Double = 0, widthM: Double = 10) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              rep.pixelsWide > 0, rep.pixelsHigh > 0 else { return nil }
        let pw = rep.pixelsWide, ph = rep.pixelsHigh
        cols = min(resolution, pw)
        rows = max(1, Int(Double(cols) * Double(ph) / Double(pw)))

        var bright = [Bool](repeating: false, count: cols * rows)
        for r in 0..<rows {
            for c in 0..<cols {
                if let color = rep.colorAt(x: c * pw / cols, y: r * ph / rows) {
                    bright[r * cols + c] = color.brightnessComponent >= 0.92
                }
            }
        }
        // hamparan terbesar
        var seen = [Bool](repeating: false, count: bright.count)
        var best: [Int] = []
        for start in bright.indices where bright[start] && !seen[start] {
            var stack = [start], cells: [Int] = []
            seen[start] = true
            while let cur = stack.popLast() {
                cells.append(cur)
                let r = cur / cols, c = cur % cols
                for (dr, dc) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                    let nr = r + dr, nc = c + dc
                    guard nr >= 0, nr < rows, nc >= 0, nc < cols else { continue }
                    let idx = nr * cols + nc
                    if bright[idx] && !seen[idx] { seen[idx] = true; stack.append(idx) }
                }
            }
            if cells.count > best.count { best = cells }
        }
        var inside = [Bool](repeating: false, count: bright.count)
        for cell in best { inside[cell] = true }
        // kikis tepi supaya garis tidak menempel dinding
        for _ in 0..<3 {
            var next = inside
            for r in 0..<rows {
                for c in 0..<cols where inside[r * cols + c] {
                    for (dr, dc) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                        let nr = r + dr, nc = c + dc
                        if nr < 0 || nr >= rows || nc < 0 || nc >= cols || !inside[nr * cols + nc] {
                            next[r * cols + c] = false
                            break
                        }
                    }
                }
            }
            inside = next
        }
        // buang lorong yang terlalu sempit: kikis, ambil hamparan terbesar,
        // lalu kembangkan lagi sebanyak yang dikikis
        if openM > 0 {
            let cellM = widthM / Double(cols)
            let steps = max(1, Int((openM / 2) / max(cellM, 1e-6)))
            var core = inside
            for _ in 0..<steps { core = FloorPlanMask.erode(core, cols: cols, rows: rows) }
            core = FloorPlanMask.largest(core, cols: cols, rows: rows)
            for _ in 0..<steps { core = FloorPlanMask.dilate(core, cols: cols, rows: rows) }
            for i in inside.indices { inside[i] = inside[i] && core[i] }
        }
        floor = inside
    }

    private static func erode(_ m: [Bool], cols: Int, rows: Int) -> [Bool] {
        var out = m
        for r in 0..<rows {
            for c in 0..<cols where m[r * cols + c] {
                for (dr, dc) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                    let nr = r + dr, nc = c + dc
                    if nr < 0 || nr >= rows || nc < 0 || nc >= cols || !m[nr * cols + nc] {
                        out[r * cols + c] = false; break
                    }
                }
            }
        }
        return out
    }

    private static func dilate(_ m: [Bool], cols: Int, rows: Int) -> [Bool] {
        var out = m
        for r in 0..<rows {
            for c in 0..<cols where !m[r * cols + c] {
                for (dr, dc) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                    let nr = r + dr, nc = c + dc
                    guard nr >= 0, nr < rows, nc >= 0, nc < cols else { continue }
                    if m[nr * cols + nc] { out[r * cols + c] = true; break }
                }
            }
        }
        return out
    }

    private static func largest(_ m: [Bool], cols: Int, rows: Int) -> [Bool] {
        var seen = [Bool](repeating: false, count: m.count)
        var best: [Int] = []
        for start in m.indices where m[start] && !seen[start] {
            var stack = [start], cells: [Int] = []
            seen[start] = true
            while let cur = stack.popLast() {
                cells.append(cur)
                let r = cur / cols, c = cur % cols
                for (dr, dc) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                    let nr = r + dr, nc = c + dc
                    guard nr >= 0, nr < rows, nc >= 0, nc < cols else { continue }
                    let idx = nr * cols + nc
                    if m[idx] && !seen[idx] { seen[idx] = true; stack.append(idx) }
                }
            }
            if cells.count > best.count { best = cells }
        }
        var out = [Bool](repeating: false, count: m.count)
        for cell in best { out[cell] = true }
        return out
    }

    func contains(_ point: CGPoint) -> Bool {
        let c = Int(Double(point.x) * Double(cols))
        let r = Int(Double(point.y) * Double(rows))
        guard c >= 0, c < cols, r >= 0, r < rows else { return false }
        return floor[r * cols + c]
    }
}
