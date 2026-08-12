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

    func post<B: Encodable, T: Decodable>(
        _ path: String,
        body: B,
        timeout: TimeInterval = 30
    ) async throws -> T {
        var req = try makeRequest(path, method: "POST")
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        return try await send(req)
    }

    func put<B: Encodable, T: Decodable>(_ path: String, body: B, timeout: TimeInterval = 30) async throws -> T {
        try await sendJSON(path, method: "PUT", body: body, timeout: timeout)
    }

    func patch<B: Encodable, T: Decodable>(_ path: String, body: B, timeout: TimeInterval = 30) async throws -> T {
        try await sendJSON(path, method: "PATCH", body: body, timeout: timeout)
    }

    func delete(_ path: String) async throws {
        let req = try makeRequest(path, method: "DELETE")
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: req) }
        catch { throw EngineError.network }
        guard let http = response as? HTTPURLResponse else { throw EngineError.network }
        guard (200..<300).contains(http.statusCode) else {
            throw EngineError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }

    private func sendJSON<B: Encodable, T: Decodable>(
        _ path: String, method: String, body: B, timeout: TimeInterval
    ) async throws -> T {
        var req = try makeRequest(path, method: method)
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        return try await send(req)
    }

    private func makeRequest(_ path: String, method: String) throws -> URLRequest {
        guard let url = URL(string: baseURL.absoluteString + path) else { throw EngineError.network }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 30
        return req
    }

    private func send<T: Decodable>(_ req: URLRequest) async throws -> T {
        let data: Data
        let resp: URLResponse
        do { (data, resp) = try await session.data(for: req) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw EngineError.network }

        guard let http = resp as? HTTPURLResponse else { throw EngineError.network }
        guard (200..<300).contains(http.statusCode) else {
            throw EngineError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw EngineError.decoding(error) }
    }
}
