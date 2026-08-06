//
//  ProcessingService.swift
//  foodcourt
//
//  Created by Shafa Tiara on 04/08/26.
//

import Foundation

enum ProcessingUpdate {
    case progress(stage: String, fraction: Double)
    case finished(AnalysisResult)
}

protocol ProcessingService {
    func run(_ session: AnalysisSession) -> AsyncThrowingStream<ProcessingUpdate, Error>
}
