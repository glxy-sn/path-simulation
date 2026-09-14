import Foundation
import CoreGraphics
import CoreImage

struct HeatmapGrid: Codable, Equatable {
    /// Fraction of measured cells reserved for the midpoint-to-high color range.
    static let highActivityFraction = 0.2
    var width: Int
    var height: Int
    var footTraffic: [Double]
    var timeSpent: [Double]
    var trackCount: Int
    var observationCount: Int

    var isValid: Bool {
        width > 0 && height > 0 && width <= 512 && height <= 512 &&
        footTraffic.count == width * height && timeSpent.count == width * height
    }

    static func fromSavedObservations(_ observations: [TrackObservation]) -> HeatmapGrid {
        let width = 56, height = 42
        var people = Array(repeating: Set<Int>(), count: width * height)
        var samples = Array(repeating: 0.0, count: width * height)
        for item in observations where item.point.x.isFinite && item.point.y.isFinite {
            let x = min(width-1, max(0, Int(item.point.x * Double(width))))
            let y = min(height-1, max(0, Int(item.point.y * Double(height))))
            people[y*width+x].insert(item.trackId)
            samples[y*width+x] += 1
        }
        return HeatmapGrid(width: width, height: height, footTraffic: people.map { Double($0.count) },
                           timeSpent: samples, trackCount: Set(observations.map(\.trackId)).count,
                           observationCount: observations.count)
    }

    /// Midranks preserve ties. Zero cells remain empty. Relative scales are per selected metric.
    static func percentileScale(_ values: [Double]) -> [Double] {
        let sorted = values.filter { $0.isFinite && $0 > 0 }.sorted()
        guard !sorted.isEmpty else { return Array(repeating: 0, count: values.count) }
        var ranks: [Double: Double] = [:]
        var index = 0
        while index < sorted.count {
            var end = index+1
            while end < sorted.count && sorted[end] == sorted[index] { end += 1 }
            ranks[sorted[index]] = Double(index+end-1)/2
            index = end
        }
        let low = ranks[sorted[0]]!, high = ranks[sorted.last!]!
        return values.map { value in
            guard let rank = ranks[value] else { return 0 }
            guard high > low else { return 0.5 }
            let percentile = (rank-low)/(high-low)
            let split = 1 - min(0.95, max(0.05, Self.highActivityFraction))
            return percentile <= split
                ? 0.05 + 0.45 * percentile/split
                : 0.5 + 0.5 * (percentile-split)/(1-split)
        }
    }

    func image(mode: Int, softened: Bool = true) -> CGImage? {
        guard isValid else { return nil }
        let raw = mode == 1 ? timeSpent : footTraffic
        // Rank only measured cells. Empty neighbors never participate in the scale.
        let scaled = Self.percentileScale(raw)
        let colors: [[Double]] = [[59,130,246],[34,197,94],[250,204,21],[239,68,68]]
        let pixelsPerCell = 8
        let imageWidth = width * pixelsPerCell, imageHeight = height * pixelsPerCell
        var bytes = [UInt8](repeating: 0, count: imageWidth*imageHeight*4)
        func occupied(_ x: Int, _ y: Int) -> Bool {
            x >= 0 && x < width && y >= 0 && y < height && raw[y*width+x].isFinite && raw[y*width+x] > 0
        }
        for y in 0..<height {
            for x in 0..<width where occupied(x,y) {
                let position = scaled[y*width+x]*3
                let lower = min(2,Int(position)), fraction = position-Double(lower)
                let rgb = (0..<3).map { c in
                    colors[lower][c]*(1-fraction)+colors[lower+1][c]*fraction
                }
                for py in 0..<pixelsPerCell {
                    for px in 0..<pixelsPerCell {
                        let u = (Double(px)+0.5)/Double(pixelsPerCell)
                        let v = (Double(py)+0.5)/Double(pixelsPerCell)
                        var edge = 1.0
                        if !occupied(x-1,y) { edge = min(edge,u*4) }
                        if !occupied(x+1,y) { edge = min(edge,(1-u)*4) }
                        if !occupied(x,y-1) { edge = min(edge,v*4) }
                        if !occupied(x,y+1) { edge = min(edge,(1-v)*4) }
                        let alpha = (185 * edge*edge*(3-2*edge)).rounded()
                        let index = ((y*pixelsPerCell+py)*imageWidth+x*pixelsPerCell+px)*4
                        // Premultiplied alpha keeps the hue stable at transparent edges.
                        for c in 0..<3 { bytes[index+c] = UInt8((rgb[c]*alpha/255).rounded()) }
                        bytes[index+3] = UInt8(alpha)
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        guard let image = CGImage(width: imageWidth, height: imageHeight, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: imageWidth*4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        guard softened else { return image }
        // Blur premultiplied color and alpha together after assigning data colors.
        // This softens geometry without ranking the artificial low-valued halo.
        let source = CIImage(cgImage: image)
        let blurred = source.applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 6.0])
        return CIContext().createCGImage(blurred, from: source.extent)
    }
}
