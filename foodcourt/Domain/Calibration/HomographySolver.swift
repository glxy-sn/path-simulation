//
//  HomographySolver.swift
//  foodcourt
//
//  Created by Shafa Tiara on 07/08/26.
//

import Foundation

enum HomographySolver {
    static let maximumPoints = 8
    static let minimumPoints = 4
    static let inlierThresholdM = 0.25

    static func floorToWorld(floorSize: PixelSize, venueWidthM: Double, venueHeightM: Double) throws -> Matrix3x3 {
        guard floorSize.isValid else { throw CalibrationError.invalidImageSize }
        guard venueWidthM > 0, venueHeightM > 0 else { throw CalibrationError.invalidVenueSize }
        return Matrix3x3([
            [venueWidthM / floorSize.width, 0, 0],
            [0, venueHeightM / floorSize.height, 0],
            [0, 0, 1]
        ])
    }

    static func invert(_ matrix: Matrix3x3) throws -> Matrix3x3 {
        let a = matrix[0, 0], b = matrix[0, 1], c = matrix[0, 2]
        let d = matrix[1, 0], e = matrix[1, 1], f = matrix[1, 2]
        let g = matrix[2, 0], h = matrix[2, 1], i = matrix[2, 2]
        let determinant = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
        guard abs(determinant) > 1e-12 else { throw CalibrationError.degeneratePoints }
        let inverse = Matrix3x3([
            [(e * i - f * h) / determinant, (c * h - b * i) / determinant, (b * f - c * e) / determinant],
            [(f * g - d * i) / determinant, (a * i - c * g) / determinant, (c * d - a * f) / determinant],
            [(d * h - e * g) / determinant, (b * g - a * h) / determinant, (a * e - b * d) / determinant]
        ])
        return normalized(inverse)
    }

    static func transform(_ points: [CalibrationPoint], with matrix: Matrix3x3) -> [CalibrationPoint] {
        points.compactMap { transform($0, with: matrix) }
    }

    static func transform(_ point: CalibrationPoint, with matrix: Matrix3x3) -> CalibrationPoint? {
        let denominator = matrix[2, 0] * point.x + matrix[2, 1] * point.y + matrix[2, 2]
        guard denominator.isFinite, abs(denominator) > 1e-12 else { return nil }
        let x = (matrix[0, 0] * point.x + matrix[0, 1] * point.y + matrix[0, 2]) / denominator
        let y = (matrix[1, 0] * point.x + matrix[1, 1] * point.y + matrix[1, 2]) / denominator
        guard x.isFinite, y.isFinite else { return nil }
        return CalibrationPoint(x: x, y: y)
    }

    static func calibrate(
        cameraPointsPx: [CalibrationPoint],
        floorPointsPx: [CalibrationPoint],
        floorSize: PixelSize,
        venueWidthM: Double,
        venueHeightM: Double
    ) throws -> CameraCalibration {
        guard cameraPointsPx.count == floorPointsPx.count else { throw CalibrationError.unequalPointCounts }
        guard cameraPointsPx.count >= minimumPoints else { throw CalibrationError.tooFewPoints }
        guard cameraPointsPx.count <= maximumPoints else { throw CalibrationError.tooManyPoints }
        guard !hasDuplicates(cameraPointsPx), !hasDuplicates(floorPointsPx) else { throw CalibrationError.duplicatePoints }

        let floorToWorld = try floorToWorld(floorSize: floorSize, venueWidthM: venueWidthM, venueHeightM: venueHeightM)
        let worldToFloor = try invert(floorToWorld)
        let floorPointsM = transform(floorPointsPx, with: floorToWorld)
        guard floorPointsM.count == floorPointsPx.count else { throw CalibrationError.degeneratePoints }

        let candidates = combinations(of: Array(cameraPointsPx.indices), choosing: minimumPoints)
        var best: Candidate?
        for indices in candidates {
            let source = indices.map { cameraPointsPx[$0] }
            let destination = indices.map { floorPointsM[$0] }
            guard let matrix = fit(source: source, destination: destination) else { continue }
            let errors = reprojectionErrors(source: cameraPointsPx, destination: floorPointsM, matrix: matrix)
            guard errors.count == cameraPointsPx.count else { continue }
            let inliers = errors.map { $0 <= inlierThresholdM }
            let score = Candidate(matrix: matrix, errors: errors, inliers: inliers)
            if score.inlierCount >= minimumPoints, best.map({ score.isBetter(than: $0) }) ?? true {
                best = score
            }
        }

        guard var chosen = best else { throw CalibrationError.noValidModel }
        for _ in 0..<2 {
            let inlierIndices = chosen.inliers.indices.filter { chosen.inliers[$0] }
            guard inlierIndices.count >= minimumPoints else { throw CalibrationError.noValidModel }
            let source = inlierIndices.map { cameraPointsPx[$0] }
            let destination = inlierIndices.map { floorPointsM[$0] }
            guard let matrix = fit(source: source, destination: destination) else { throw CalibrationError.degeneratePoints }
            let errors = reprojectionErrors(source: cameraPointsPx, destination: floorPointsM, matrix: matrix)
            guard errors.count == cameraPointsPx.count else { throw CalibrationError.noValidModel }
            chosen = Candidate(matrix: matrix, errors: errors, inliers: errors.map { $0 <= inlierThresholdM })
        }

        let projectedWorld = transform(cameraPointsPx, with: chosen.matrix)
        guard projectedWorld.count == cameraPointsPx.count else { throw CalibrationError.noValidModel }
        let projectedFloor = transform(projectedWorld, with: worldToFloor)
        guard projectedFloor.count == cameraPointsPx.count else { throw CalibrationError.noValidModel }
        return CameraCalibration(
            homographyCameraToWorld: chosen.matrix,
            cameraPointsPx: cameraPointsPx,
            floorPointsPx: floorPointsPx,
            floorPointsM: floorPointsM,
            projectedFloorPointsPx: projectedFloor,
            inlierMask: chosen.inliers,
            reprojectionErrorsM: chosen.errors,
            metrics: CalibrationMetrics(
                medianErrorM: percentile(chosen.errors, 0.5),
                p95ErrorM: percentile(chosen.errors, 0.95),
                inliers: chosen.inlierCount,
                points: chosen.errors.count
            )
        )
    }

    private struct Candidate {
        let matrix: Matrix3x3
        let errors: [Double]
        let inliers: [Bool]

        var inlierCount: Int { inliers.filter { $0 }.count }
        var inlierMedian: Double {
            let values = zip(errors, inliers).compactMap { $0.1 ? $0.0 : nil }
            return percentile(values, 0.5)
        }
        var totalError: Double { errors.reduce(0, +) }

        func isBetter(than other: Candidate) -> Bool {
            if inlierCount != other.inlierCount { return inlierCount > other.inlierCount }
            if abs(inlierMedian - other.inlierMedian) > 1e-10 { return inlierMedian < other.inlierMedian }
            return totalError < other.totalError
        }
    }

    private static func fit(source: [CalibrationPoint], destination: [CalibrationPoint]) -> Matrix3x3? {
        guard source.count == destination.count, source.count >= minimumPoints else { return nil }
        guard let sourceTransform = normalizationTransform(source), let destinationTransform = normalizationTransform(destination) else { return nil }
        let normalizedSource = transform(source, with: sourceTransform)
        let normalizedDestination = transform(destination, with: destinationTransform)
        guard normalizedSource.count == source.count, normalizedDestination.count == destination.count else { return nil }

        var normal = Array(repeating: Array(repeating: 0.0, count: 8), count: 8)
        var rhs = Array(repeating: 0.0, count: 8)
        for (s, d) in zip(normalizedSource, normalizedDestination) {
            let rows: [([Double], Double)] = [
                ([s.x, s.y, 1, 0, 0, 0, -d.x * s.x, -d.x * s.y], d.x),
                ([0, 0, 0, s.x, s.y, 1, -d.y * s.x, -d.y * s.y], d.y)
            ]
            for (row, value) in rows {
                for i in 0..<8 {
                    rhs[i] += row[i] * value
                    for j in 0..<8 { normal[i][j] += row[i] * row[j] }
                }
            }
        }
        guard let coefficients = solve(normal, rhs) else { return nil }
        let normalizedMatrix = Matrix3x3([
            [coefficients[0], coefficients[1], coefficients[2]],
            [coefficients[3], coefficients[4], coefficients[5]],
            [coefficients[6], coefficients[7], 1]
        ])
        guard let inverseDestination = try? invert(destinationTransform) else { return nil }
        return normalized(multiply(multiply(inverseDestination, normalizedMatrix), sourceTransform))
    }

    private static func normalizationTransform(_ points: [CalibrationPoint]) -> Matrix3x3? {
        guard !points.isEmpty else { return nil }
        let centerX = points.map(\.x).reduce(0, +) / Double(points.count)
        let centerY = points.map(\.y).reduce(0, +) / Double(points.count)
        let meanDistance = points.map { hypot($0.x - centerX, $0.y - centerY) }.reduce(0, +) / Double(points.count)
        guard meanDistance > 1e-9 else { return nil }
        let scale = sqrt(2) / meanDistance
        return Matrix3x3([[scale, 0, -scale * centerX], [0, scale, -scale * centerY], [0, 0, 1]])
    }

    private static func multiply(_ lhs: Matrix3x3, _ rhs: Matrix3x3) -> Matrix3x3 {
        var result = Array(repeating: Array(repeating: 0.0, count: 3), count: 3)
        for row in 0..<3 {
            for column in 0..<3 {
                result[row][column] = (0..<3).reduce(0) { $0 + lhs[row, $1] * rhs[$1, column] }
            }
        }
        return Matrix3x3(result)
    }

    private static func normalized(_ matrix: Matrix3x3) -> Matrix3x3 {
        let scale = abs(matrix[2, 2]) > 1e-12 ? matrix[2, 2] : 1
        return Matrix3x3(matrix.values.map { $0.map { $0 / scale } })
    }

    private static func solve(_ matrix: [[Double]], _ rhs: [Double]) -> [Double]? {
        var augmented = zip(matrix, rhs).map { $0.0 + [$0.1] }
        let count = rhs.count
        for pivot in 0..<count {
            let row = (pivot..<count).max { abs(augmented[$0][pivot]) < abs(augmented[$1][pivot]) } ?? pivot
            guard abs(augmented[row][pivot]) > 1e-12 else { return nil }
            if row != pivot { augmented.swapAt(row, pivot) }
            let divisor = augmented[pivot][pivot]
            for column in pivot...count { augmented[pivot][column] /= divisor }
            for target in 0..<count where target != pivot {
                let factor = augmented[target][pivot]
                guard factor != 0 else { continue }
                for column in pivot...count { augmented[target][column] -= factor * augmented[pivot][column] }
            }
        }
        return augmented.map { $0[count] }
    }

    private static func reprojectionErrors(source: [CalibrationPoint], destination: [CalibrationPoint], matrix: Matrix3x3) -> [Double] {
        zip(source, destination).compactMap { source, destination in
            guard let projected = transform(source, with: matrix) else { return nil }
            return hypot(projected.x - destination.x, projected.y - destination.y)
        }
    }

    private static func hasDuplicates(_ points: [CalibrationPoint]) -> Bool {
        for first in points.indices {
            for second in points.indices where second > first {
                if hypot(points[first].x - points[second].x, points[first].y - points[second].y) < 1e-6 { return true }
            }
        }
        return false
    }

    private static func combinations(of values: [Int], choosing count: Int) -> [[Int]] {
        guard count > 0, count <= values.count else { return [] }
        var result: [[Int]] = []
        func visit(_ start: Int, _ current: [Int]) {
            if current.count == count { result.append(current); return }
            let remaining = count - current.count
            guard start <= values.count - remaining else { return }
            for index in start...(values.count - remaining) { visit(index + 1, current + [values[index]]) }
        }
        visit(0, [])
        return result
    }

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))
        return sorted[index]
    }
}
