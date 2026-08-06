//
//  Sidecar.swift
//  foodcourt
//
//  Created by Shafa Tiara on 04/08/26.
//

import Foundation
import Observation

@Observable
final class Sidecar {
    let baseURL: URL
    let http: HTTPClient
    var device: String = ""
    var isReady = false

    init(baseURL: URL = URL(string: "http://127.0.0.1:8765")!) {
        self.baseURL = baseURL
        self.http = HTTPClient(baseURL: baseURL)
    }

    private struct Health: Decodable { let status: String; let device: String }

    @discardableResult
    func checkHealth() async -> Bool {
        do {
            let h: Health = try await http.get("/health")
            device = h.device
            isReady = (h.status == "ok")
            return isReady
        } catch {
            isReady = false
            return false
        }
    }

    /// Tunggu server siap (polling). Return false kalau timeout.
    func waitUntilReady(timeout: TimeInterval = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await checkHealth() { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    // TODO(bundling): spawn engine.
    //   let p = Process()
    //   p.executableURL = <python bundled>
    //   p.arguments = [<server.py>]
    //   try p.run()
    // lalu waitUntilReady(), dan terminate() saat app quit.
}
