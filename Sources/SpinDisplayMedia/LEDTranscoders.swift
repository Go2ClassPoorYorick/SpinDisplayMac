import Foundation
import SpinDisplayCore

/// Pixels as the original read them: `Bitmap2Byte` saved a GDI+ bitmap as BMP and skipped the 54-byte
/// header, so rows run bottom-up and channels are B, G, R(, A). Mold indexes address that layout.
struct BMPPixels {
    let bytes: [UInt8]
    let pixelCount: Int

    /// 32-bit BGRA, bottom-up (the JpgBinTool path: frames are 32bpp ARGB bitmaps).
    static func bgra(fromRGBA rgba: [UInt8], width: Int, height: Int) -> BMPPixels {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let source = (height - 1 - y) * width * 4
            let destination = y * width * 4
            for x in 0..<width {
                bytes[destination + x * 4] = rgba[source + x * 4 + 2]
                bytes[destination + x * 4 + 1] = rgba[source + x * 4 + 1]
                bytes[destination + x * 4 + 2] = rgba[source + x * 4]
                bytes[destination + x * 4 + 3] = 255
            }
        }
        return BMPPixels(bytes: bytes, pixelCount: width * height)
    }

    /// 24-bit BGR, bottom-up, rows padded to 4 bytes (the BinTool path: frames load as 24bpp JPEGs).
    /// The original indexes these as `pixel * 3`, ignoring row padding, exactly as reproduced here.
    static func bgr(fromRGBA rgba: [UInt8], width: Int, height: Int) -> BMPPixels {
        let stride = (width * 3 + 3) / 4 * 4
        var bytes = [UInt8](repeating: 0, count: stride * height)
        for y in 0..<height {
            let source = (height - 1 - y) * width * 4
            let destination = y * stride
            for x in 0..<width {
                bytes[destination + x * 3] = rgba[source + x * 4 + 2]
                bytes[destination + x * 3 + 1] = rgba[source + x * 4 + 1]
                bytes[destination + x * 3 + 2] = rgba[source + x * 4]
            }
        }
        return BMPPixels(bytes: bytes, pixelCount: width * height)
    }
}

/// .NET `conv.u1` on a double: truncate toward zero, then keep the low byte.
@inline(__always) private func byteTruncating(_ value: Double) -> UInt8 {
    UInt8(truncatingIfNeeded: Int(value))
}

/// Original `F20AD.Connect.JpgBinTool`: remaps a square frame onto the fan's LED layout ("molds") and
/// encodes the result as a JPEG whose width is the padded LED count and whose height is
/// `times × 8 × lightBarCount`. Used by content-type-3 fans for uploads and projection, and by the
/// Export window's device types 25 and 26.
public final class MoldTranscoder {
    public let ledCount: Int
    public let rows: Int
    public let lightBarCount: Int
    public let quality: Int
    public let covering: Int
    let times: Int
    let perNum: Int
    let perBar: Int
    let orientation: Int
    let adjust: [UInt8]
    let lights: [Double]
    let imageWidth: Int
    public private(set) var molds: [Int32] = []

    public var outputWidth: Int { ledCount + covering }
    public var outputHeight: Int { times * 8 * lightBarCount }

    /// Arguments follow the original constructor (its colour argument is ignored: it always uses BGR).
    public init(
        ledCount: Int, rows: Int, orientation: Int, adjust: [UInt8]?, lights: [UInt8]?,
        perBar: Int, lightBarCount: Int, quality: Int, imageWidth: Int
    ) {
        self.ledCount = ledCount
        self.rows = rows
        self.orientation = orientation
        self.perBar = max(1, perBar)
        self.lightBarCount = max(1, lightBarCount)
        self.quality = quality
        self.imageWidth = imageWidth
        let padded = Int((Double(ledCount) / 16).rounded(.up)) * 16
        perNum = rows / max(1, lightBarCount)
        times = Int((Double(perNum) / 8).rounded(.up))
        covering = padded - ledCount
        if let adjust, adjust.count >= 256 {
            self.adjust = Array(adjust.prefix(256))
        } else {
            self.adjust = (0..<256).map { UInt8($0) }
        }
        let total = ledCount + covering
        if let lights {
            let offset = total - lights.count
            self.lights = (0..<total).map { $0 < offset ? 1 : Double(lights[$0 - offset]) * 0.01 }
        } else {
            self.lights = Array(repeating: 1, count: total)
        }
        takeMold(width: imageWidth, height: imageWidth)
    }

    public convenience init(transcoding: FanTranscoding, imageWidth: Int) {
        self.init(
            ledCount: transcoding.ledCount, rows: transcoding.rows, orientation: transcoding.direction,
            adjust: transcoding.adjust, lights: transcoding.ratio, perBar: transcoding.deliveryTimes,
            lightBarCount: transcoding.lightBarCount, quality: transcoding.quality, imageWidth: imageWidth
        )
    }

    /// The Export window's fixed presets for device types 25 and 26.
    public static func exportPreset(deviceType: UInt8, imageWidth: Int) -> MoldTranscoder? {
        switch deviceType {
        case 25:
            return MoldTranscoder(ledCount: 296, rows: 1344, orientation: 0, adjust: nil, lights: nil,
                                  perBar: 2, lightBarCount: 4, quality: 90, imageWidth: imageWidth)
        case 26:
            return MoldTranscoder(ledCount: 256, rows: 1408, orientation: 0, adjust: nil, lights: nil,
                                  perBar: 2, lightBarCount: 4, quality: 90, imageWidth: imageWidth)
        default:
            return nil
        }
    }

    private func takeMold(width: Int, height: Int) {
        let centerX = Double(width / 2) + 1.5
        let centerY = Double(height / 2) + 1.5
        let radius = Double(min(width, height)) / 2 - 3
        var step = 360 / Double(rows)
        if orientation != 0 { step = -step }
        let ledStep = radius / Double(ledCount)
        let groups = lightBarCount / perBar
        molds = []
        molds.reserveCapacity((ledCount + covering) * times * 8 * lightBarCount)
        for bar in 0..<perBar {
            for time in 0..<times {
                for group in 0..<groups {
                    var angle = Double(time * 8 + (bar * groups + group) * perNum) * step
                    for _ in 0..<8 {
                        molds.append(contentsOf: repeatElement(-1, count: covering))
                        var distance = radius
                        let sine = sin(angle * .pi / 180), cosine = cos(angle * .pi / 180)
                        for _ in 0..<ledCount {
                            // .NET Math.Round is banker's rounding.
                            let x = Int((distance * cosine + centerX).rounded(.toNearestOrEven))
                            let y = Int((centerY - distance * sine).rounded(.toNearestOrEven))
                            molds.append(Int32(truncatingIfNeeded: (y - 1) * width + x - 1))
                            distance -= ledStep
                        }
                        angle += step
                    }
                }
            }
        }
    }

    /// `toMoldsBGR`: one B, G, R triple per mold slot.
    public func moldBytes(rgba: [UInt8], width: Int, height: Int) -> [UInt8] {
        let pixels = BMPPixels.bgra(fromRGBA: rgba, width: width, height: height)
        let slotsPerLine = ledCount + covering
        var output = [UInt8](repeating: 0, count: molds.count * 3)
        for (slot, mold) in molds.enumerated() {
            let index = Int(mold)
            guard index >= 0, index < pixels.pixelCount else { continue }
            let light = lights[slot % slotsPerLine]
            output[slot * 3] = byteTruncating(Double(adjust[Int(pixels.bytes[index * 4])]) * light)
            output[slot * 3 + 1] = byteTruncating(Double(adjust[Int(pixels.bytes[index * 4 + 1])]) * light)
            output[slot * 3 + 2] = byteTruncating(Double(adjust[Int(pixels.bytes[index * 4 + 2])]) * light)
        }
        return output
    }

    /// The mold image as a 4:2:0 JPEG (`TurboLibjpeg.bytesToJpeg`, TJPF_BGR). Projection uses quality 90.
    public func jpeg(rgba: [UInt8], width: Int, height: Int, quality: Int? = nil) -> Data {
        let bgr = moldBytes(rgba: rgba, width: width, height: height)
        var image = [UInt8](repeating: 255, count: outputWidth * outputHeight * 4)
        for slot in 0..<(outputWidth * outputHeight) {
            image[slot * 4] = bgr[slot * 3 + 2]
            image[slot * 4 + 1] = bgr[slot * 3 + 1]
            image[slot * 4 + 2] = bgr[slot * 3]
        }
        return BaselineJPEGEncoder.encode(rgba: image, width: outputWidth, height: outputHeight,
                                          quality: quality ?? self.quality, subsampling: .s420)
    }
}

/// Original `F20AD.Connect.BinTool`: remaps a frame onto the fan's LEDs and packs it into bit planes
/// (`toPov`) for content-type-1 fans, which receive frames over the bin protocol (`0x38`).
public final class BinTranscoder {
    let configuration: FanBinConfiguration
    let perBar: Int
    public private(set) var molds: [Int32] = []

    public init(configuration: FanBinConfiguration, imageWidth: Int) {
        self.configuration = configuration
        perBar = configuration.perBar != 0 ? configuration.perBar : configuration.lamps
        takeMold(width: imageWidth, height: imageWidth)
    }

    private func takeMold(width: Int, height: Int) {
        let centerX = Double(width / 2) + 1.5
        let centerY = Double(height / 2) + 1.5
        let radius = Double(min(width, height)) / 2 - 3
        var step = 360 / Double(configuration.rows)
        if configuration.orientation != 0 { step = -step }
        let ledStep = radius / Double(configuration.ledCount)
        var angle = 0.0
        molds = []
        molds.reserveCapacity(configuration.ledCount * configuration.rows)
        for _ in 0..<configuration.rows {
            var distance = radius
            let sine = sin(angle * .pi / 180), cosine = cos(angle * .pi / 180)
            for _ in 0..<configuration.ledCount {
                // `conv.i4` truncates toward zero here (no rounding, unlike JpgBinTool).
                let x = Int(distance * cosine + centerX)
                let y = Int(centerY - distance * sine)
                molds.append(Int32(truncatingIfNeeded: (y - 1) * width + x - 1))
                distance -= ledStep
            }
            angle += step
        }
    }

    /// `toMolds*`: the colour order names the output channel order (for example BRG writes B, R, G).
    public func moldBytes(rgba: [UInt8], width: Int, height: Int) -> [UInt8]? {
        // Source channel offsets in a 24-bit BMP: B = 0, G = 1, R = 2. Unknown orders fail, as in the original.
        let orders: [[Int]] = [[0, 2, 1], [0, 1, 2], [1, 2, 0], [1, 0, 2], [2, 1, 0], [2, 0, 1]]
        guard orders.indices.contains(configuration.color) else { return nil }
        let order = orders[configuration.color]
        let pixels = BMPPixels.bgr(fromRGBA: rgba, width: width, height: height)
        var output = [UInt8](repeating: 0, count: molds.count * 3)
        for (slot, mold) in molds.enumerated() {
            let base = Int(mold) * 3
            guard base >= 0, base + 2 < pixels.bytes.count else { continue }
            let light = configuration.lights[slot % configuration.ledCount]
            for channel in 0..<3 {
                output[slot * 3 + channel] = byteTruncating(
                    Double(configuration.adjust[Int(pixels.bytes[base + order[channel]])]) * light
                )
            }
        }
        return output
    }

    /// `toBin`: mold bytes packed into `bit` bit planes, MSB first.
    public func encode(rgba: [UInt8], width: Int, height: Int) -> Data? {
        guard let bytes = moldBytes(rgba: rgba, width: width, height: height) else { return nil }
        return Data(Self.pack(bytes, configuration: configuration, perBar: perBar))
    }

    public static func pack(_ bytes: [UInt8], configuration: FanBinConfiguration, perBar: Int) -> [UInt8] {
        let barCount = max(1, configuration.lamps)
        let subsection = max(1, configuration.subsection)
        var output = [UInt8](repeating: 0, count: bytes.count * configuration.bit / 8)
        let bytesPerBar = bytes.count / barCount
        let rowsPerBar = configuration.rows / barCount
        let rowBytes = configuration.ledCount * 3
        let segmentLength = rowBytes / subsection
        let groups = max(1, barCount / max(1, perBar))
        let groupStride = bytes.count / groups
        var outputMask: UInt8 = 0x80
        var outputIndex = 0
        for group in 0..<groups {
            for row in 0..<rowsPerBar {
                var bitMask: UInt8 = 0x80
                for _ in 0..<configuration.bit {
                    for segment in 0..<segmentLength {
                        let base = group * groupStride + row * rowBytes + segment
                        for bar in 0..<(barCount / groups) {
                            var index = base + bar * bytesPerBar
                            for _ in 0..<subsection {
                                if index < bytes.count, outputIndex < output.count, bytes[index] & bitMask > 0 {
                                    output[outputIndex] |= outputMask
                                }
                                outputMask >>= 1
                                if outputMask == 0 {
                                    outputMask = 0x80
                                    outputIndex += 1
                                }
                                index += segmentLength
                            }
                        }
                    }
                    bitMask >>= 1
                }
            }
        }
        return output
    }
}
