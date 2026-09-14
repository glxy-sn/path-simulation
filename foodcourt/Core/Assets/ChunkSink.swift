//
//  ChunkSink.swift
//  foodcourt
//
//  Menulis balasan HTTP ke disk potongan demi potongan. `URLSession.bytes`
//  menghasilkan satu bita per iterasi, yang terlalu lambat untuk berkas 4,7 GB,
//  sedangkan `URLSession.data` menahan seluruh isinya di memori.
//

import Foundation

final class ChunkSink: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var received: Int64
    private var continuation: CheckedContinuation<Void, Error>?
    private var finished = false

    /// Dipanggil dari antrean delegate, bukan main actor.
    var onProgress: ((Int64) -> Void)?

    init(fileURL: URL, alreadyHave: Int64) throws {
        handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        received = alreadyHave
        super.init()
    }

    func run(request: URLRequest, session: URLSession) async throws {
        let delegateSession = URLSession(configuration: session.configuration, delegate: self, delegateQueue: nil)
        defer { delegateSession.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                lock.unlock()
                delegateSession.dataTask(with: request).resume()
            }
        } onCancel: {
            delegateSession.invalidateAndCancel()
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard !finished, let continuation else { lock.unlock(); return }
        finished = true
        self.continuation = nil
        lock.unlock()
        try? handle.close()
        continuation.resume(with: result)
    }

    // MARK: URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.allow)
            return
        }
        guard (200...299).contains(http.statusCode) else {
            completionHandler(.cancel)
            finish(.failure(AssetError.badResponse(dataTask.originalRequest?.url?.lastPathComponent ?? "asset", http.statusCode)))
            return
        }
        // Server yang mengabaikan header Range membalas 200 dengan seluruh isi
        // berkas. Menambahkannya ke sisa unduhan lama akan menghasilkan berkas
        // rusak yang baru ketahuan saat pemeriksaan checksum, jadi mulai ulang.
        if http.statusCode == 200, received > 0 {
            lock.lock()
            try? handle.truncate(atOffset: 0)
            received = 0
            lock.unlock()
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        do {
            try handle.write(contentsOf: data)
            received += Int64(data.count)
        } catch {
            lock.unlock()
            finish(.failure(error))
            return
        }
        let snapshot = received
        lock.unlock()
        onProgress?(snapshot)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
        } else {
            finish(.success(()))
        }
    }
}
