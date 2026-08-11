//
//  AppRouter.swift
//  foodcourt
//
//  Created by Shafa Tiara on 03/08/26.
//

import SwiftUI
import Observation


enum AppSection: Hashable {
    case newAnalysis
    case history

    var title: String {
        switch self {
        case .newAnalysis: return "Analisis Baru"
        case .history:     return "Riwayat"
        }
    }
    var systemImage: String {
        switch self {
        case .newAnalysis: return "plus.viewfinder"
        case .history:     return "clock.arrow.circlepath"
        }
    }
}

enum FlowStep: Int, CaseIterable, Identifiable {
    case importFootage = 0
    case calibration
    case processing
    case results

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .importFootage: return "Import"
        case .calibration:   return "Kalibrasi"
        case .processing:    return "Proses"
        case .results:       return "Hasil"
        }
    }

    var systemImage: String {
        switch self {
        case .importFootage: return "square.and.arrow.down"
        case .calibration:   return "grid"
        case .processing:    return "gearshape.2"
        case .results:       return "chart.bar.xaxis"
        }
    }
}

@Observable
final class AppRouter {
    var section: AppSection = .newAnalysis
    var step: FlowStep = .importFootage

    func go(to step: FlowStep) { self.step = step }
    func next() { if let n = FlowStep(rawValue: step.rawValue + 1) { step = n } }
    func back() { if let p = FlowStep(rawValue: step.rawValue - 1) { step = p } }

    func open(_ section: AppSection) { self.section = section }
    func startNew() { section = .newAnalysis; step = .importFootage }
    func openResult() { section = .newAnalysis; step = .results }
}
