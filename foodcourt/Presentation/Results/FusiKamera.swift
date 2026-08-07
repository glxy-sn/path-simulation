//
//  FusiKamera.swift
//  foodcourt
//
//  Menyatukan nomor orang antar kamera: satu orang, satu nomor.
//
//  Pencocokan lintas kamera lewat EMBEDDING Re-ID sudah diukur di data ini dan
//  hasilnya ~20% benar — tidak layak dipakai. Tapi itu sebelum ada kalibrasi.
//
//  Di sini yang dibandingkan POSISI DI LANTAI, dan itu bukti yang jauh lebih
//  keras daripada kemiripan baju: dua orang berbeda tidak bisa berdiri di
//  koordinat yang sama pada detik yang sama. Yang dibutuhkan cuma kedua kamera
//  terkalibrasi ke ruangan yang sama — dan itu memang syarat mode denah.
//
//  Aturannya sengaja ketat, dan lebih baik TIDAK menggabungkan daripada salah
//  menggabungkan: dua orang yang keliru disatukan akan tergambar sebagai satu
//  lintasan melompat antar meja, dan itu kebohongan yang tidak kelihatan.
//

import Foundation
import CoreGraphics

enum FusiKamera {
    /// Satu track: kamera ke berapa, dan nomor ID di kamera itu.
    struct Kunci: Hashable {
        let kamera: Int
        let tid: String
    }

    struct Hasil {
        /// Nomor bersama untuk tiap track. Track yang tidak berpasangan tetap
        /// dapat nomornya sendiri — hanya saja tidak dibagi dengan siapa pun.
        let nomor: [Kunci: Int]
        /// Berapa pasang yang benar-benar digabungkan.
        let digabung: Int
        /// Berapa orang setelah digabung.
        let jumlahOrang: Int
    }

    /// Jarak maksimum yang masih dianggap orang yang sama, dalam meter.
    ///
    /// Titik yang dipakai adalah TITIK KAKI, dan galat kalibrasi di data ini
    /// bermedian beberapa sentimeter. Satu meter memberi ruang untuk galat
    /// kalibrasi dan kotak deteksi yang bergoyang, tapi masih jauh lebih rapat
    /// daripada jarak antar-kursi (kira-kira 0,6–0,8 m di meja panjang, lebih
    /// jauh antar meja).
    static let ambangMeter: CGFloat = 1.0

    /// Berapa cuplikan waktu minimal yang harus bertindih sebelum dua track
    /// boleh disatukan. Satu-dua kebetulan tidak cukup.
    static let minimalTindih = 5

    static func gabungkan(_ kamera: [AnalysisResult]) -> Hasil {
        // Posisi lantai tiap track, per frame.
        var lantai: [Kunci: [Int: CGPoint]] = [:]
        for (i, k) in kamera.enumerated() {
            guard k.adaDenah else { continue }
            for (tid, deret) in k.jejakWaktu {
                var titik: [Int: CGPoint] = [:]
                for t in deret {
                    if let m = k.keLantai(t.titik) { titik[t.frame] = m }
                }
                if !titik.isEmpty { lantai[Kunci(kamera: i, tid: tid)] = titik }
            }
        }

        // Semua pasangan lintas-kamera yang layak, dengan jarak medianya.
        struct Calon { let a: Kunci, b: Kunci; let jarak: CGFloat; let tindih: Int }
        var calon: [Calon] = []
        let kunci = Array(lantai.keys)
        for i in kunci.indices {
            for j in (i + 1)..<kunci.count where kunci[i].kamera != kunci[j].kamera {
                let a = kunci[i], b = kunci[j]
                guard let pa = lantai[a], let pb = lantai[b] else { continue }
                var jarak: [CGFloat] = []
                for (f, p) in pa {
                    if let q = pb[f] { jarak.append(hypot(p.x - q.x, p.y - q.y)) }
                }
                guard jarak.count >= minimalTindih else { continue }
                jarak.sort()
                // MEDIAN, bukan rata-rata: satu frame di mana kotak deteksinya
                // meleset tidak boleh membatalkan pasangan yang selebihnya rapat.
                let med = jarak[jarak.count / 2]
                guard med <= ambangMeter else { continue }
                calon.append(Calon(a: a, b: b, jarak: med, tindih: jarak.count))
            }
        }

        // Yang paling rapat dipasangkan lebih dulu, dan tiap track cuma boleh
        // dipakai sekali. Serakah, tapi cukup: pasangan yang benar hampir
        // selalu jauh lebih rapat daripada tetangga terdekat berikutnya.
        calon.sort { $0.jarak == $1.jarak ? $0.tindih > $1.tindih : $0.jarak < $1.jarak }
        var pasangan: [Kunci: Kunci] = [:]
        var terpakai: Set<Kunci> = []
        for c in calon where !terpakai.contains(c.a) && !terpakai.contains(c.b) {
            pasangan[c.a] = c.b
            terpakai.insert(c.a); terpakai.insert(c.b)
        }

        // Penomoran: pasangan dapat satu nomor, sisanya nomor sendiri-sendiri.
        // Diurutkan supaya nomornya tidak berubah tiap layar digambar ulang.
        var nomor: [Kunci: Int] = [:]
        var n = 1
        for k in kunci.sorted(by: { ($0.kamera, $0.tid) < ($1.kamera, $1.tid) }) {
            if nomor[k] != nil { continue }
            nomor[k] = n
            if let lain = pasangan[k] { nomor[lain] = n }
            n += 1
        }
        return Hasil(nomor: nomor, digabung: pasangan.count, jumlahOrang: n - 1)
    }

    /// Warna untuk nomor orang ke-`i` dari `total`.
    ///
    /// Rona dibagi rata memakai sudut emas, BUKAN diambil dari nilai hash.
    /// Hash membagi rona secara acak, dan acak berarti tabrakan: dengan 60
    /// orang, peluang ada dua yang ronanya berselisih di bawah 5 derajat
    /// praktis satu. Sudut emas menjamin nomor-nomor berdekatan berjauhan
    /// warnanya, dan sebarannya tetap rata berapa pun jumlah orangnya.
    ///
    /// Terang dan jenuhnya digilir tiga tingkat supaya rona yang mau tak mau
    /// berulang di kerumunan besar tetap bisa dibedakan.
    static func warna(nomor: Int) -> (rona: Double, jenuh: Double, terang: Double) {
        let i = max(0, nomor - 1)
        let rona = (Double(i) * 0.618033988749895).truncatingRemainder(dividingBy: 1)
        let tingkat = i % 3
        return (rona,
                [0.85, 0.62, 0.95][tingkat],
                [0.80, 0.92, 0.62][tingkat])
    }
}
