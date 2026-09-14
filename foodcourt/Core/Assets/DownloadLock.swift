//
//  DownloadLock.swift
//  foodcourt
//
//  Kunci antar-proses supaya dua salinan Foodcourt tidak mengunduh berkas yang
//  sama ke berkas .part yang sama.
//

import Foundation

final class DownloadLock {
    private let descriptor: Int32

    /// Mengembalikan nil kalau proses lain sedang memegang kunci.
    init?(at url: URL) {
        descriptor = open(url.path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { return nil }
        // flock dilepas otomatis oleh kernel kalau proses mati mendadak, jadi
        // aplikasi yang di-force quit tidak meninggalkan kunci yang macet.
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
    }

    func release() {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
