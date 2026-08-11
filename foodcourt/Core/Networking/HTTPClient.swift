//
//  HTTPClient.swift
//  foodcourt
//
//  Created by Shafa Tiara on 04/08/26.
//

import Foundation

enum EngineError: Error, LocalizedError {
    case network
    case notReady
    case http(Int, String)
    case decoding(Error)
    case job(String)

    var errorDescription: String? {
        switch self {
        case .network:            return "Gagal terhubung ke engine."
        case .notReady:           return "Engine belum siap. Pastikan server jalan di :8765."
        case .http(let c, let m): return "HTTP \(c): \(m)"
        case .decoding(let e):    return "Gagal membaca respons: \(e.localizedDescription)"
        case .job(let m):         return m
        }
    }
}

struct HTTPClient {
    let baseURL: URL
    var session: URLSession = .shared

    func get<T: Decodable>(_ path: String) async throws -> T {
        try await send(makeRequest(path, method: "GET"))
    }

    /// `timeout` bisa dinaikkan untuk permintaan yang memang lama. Chat ke LLM
    /// lokal butuh 20–90 detik di Mac ini; dengan batas 30 detik bawaan,
    /// jawaban yang sebenarnya sedang disusun akan tampil sebagai "gagal
    /// terhubung ke engine".
    func post<B: Encodable, T: Decodable>(_ path: String, body: B,
                                          timeout: TimeInterval = 30) async throws -> T {
        var req = try makeRequest(path, method: "POST", timeout: timeout)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        return try await send(req)
    }

    private func makeRequest(_ path: String, method: String,
                             timeout: TimeInterval = 30) throws -> URLRequest {
        guard let url = URL(string: baseURL.absoluteString + path) else { throw EngineError.network }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        return req
    }

    private func send<T: Decodable>(_ req: URLRequest) async throws -> T {
        let data: Data
        let resp: URLResponse
        do { (data, resp) = try await session.data(for: req) }
        catch { throw EngineError.network }

        guard let http = resp as? HTTPURLResponse else { throw EngineError.network }
        guard (200..<300).contains(http.statusCode) else {
            throw EngineError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw EngineError.decoding(error) }
    }
}
