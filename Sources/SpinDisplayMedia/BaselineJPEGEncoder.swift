import Foundation

/// A minimal baseline JPEG encoder that produces the same stream structure as the original client's
/// libjpeg-turbo calls (`tjCompress(…, TJSAMP_444, quality 80, flags 0)` for uploads and
/// `TJSAMP_420`, quality 30 for projection): SOI, JFIF APP0, two quantization tables, SOF0, the standard
/// Huffman tables, one interleaved scan without restart markers, EOI.
///
/// ImageIO instead writes 4:2:0 data with Exif/Photoshop segments and a restart interval, which
/// small embedded decoders may not accept.
public enum BaselineJPEGEncoder {
    public enum Subsampling: Sendable {
        /// Full-resolution chroma, used by the original for uploaded media (`TJSAMP_444`).
        case s444
        /// 2×2 chroma averaging, used by the original for screen projection (`TJSAMP_420`).
        case s420

        var factor: Int { self == .s444 ? 1 : 2 }
    }

    /// Encodes tightly packed RGBA (or RGBX) pixels; alpha is ignored.
    public static func encode(rgba: [UInt8], width: Int, height: Int, quality: Int = 80, subsampling: Subsampling = .s444) -> Data {
        precondition(width > 0 && height > 0 && rgba.count >= width * height * 4)
        let luminanceTable = scaledTable(standardLuminance, quality: quality)
        let chrominanceTable = scaledTable(standardChrominance, quality: quality)
        let factor = subsampling.factor

        var output = Data()
        output.reserveCapacity(width * height / 2)
        writeHeaders(into: &output, width: width, height: height, luminance: luminanceTable,
                     chrominance: chrominanceTable, lumaSampling: UInt8(factor << 4 | factor))

        // JFIF / libjpeg RGB → YCbCr planes, level-shifted by 128 for the DCT.
        let count = width * height
        var lumaPlane = [Float](repeating: 0, count: count)
        var blueChroma = [Float](repeating: 0, count: count)
        var redChroma = [Float](repeating: 0, count: count)
        rgba.withUnsafeBufferPointer { pixels in
            for index in 0..<count {
                let r = Float(pixels[index * 4]), g = Float(pixels[index * 4 + 1]), b = Float(pixels[index * 4 + 2])
                lumaPlane[index] = 0.299 * r + 0.587 * g + 0.114 * b - 128
                blueChroma[index] = -0.168_735_89 * r - 0.331_264_11 * g + 0.5 * b
                redChroma[index] = 0.5 * r - 0.418_687_59 * g - 0.081_312_41 * b
            }
        }

        let luminanceDivisors = luminanceTable.map { Float($0) }
        let chrominanceDivisors = chrominanceTable.map { Float($0) }
        var writer = BitWriter()
        var previousDC = [0, 0, 0]
        var block = [Float](repeating: 0, count: 64)
        var coefficients = [Int](repeating: 0, count: 64)
        let mcuSize = 8 * factor

        func fillLuma(x originX: Int, y originY: Int) {
            for row in 0..<8 {
                let sourceY = min(originY + row, height - 1)
                for column in 0..<8 {
                    block[row * 8 + column] = lumaPlane[sourceY * width + min(originX + column, width - 1)]
                }
            }
        }

        // Each chroma sample averages a factor × factor pixel area (edges repeat the last pixel).
        func fillChroma(_ plane: [Float], x originX: Int, y originY: Int) {
            let weight = 1 / Float(factor * factor)
            for row in 0..<8 {
                for column in 0..<8 {
                    var sum: Float = 0
                    for dy in 0..<factor {
                        let sourceY = min(originY + row * factor + dy, height - 1)
                        for dx in 0..<factor {
                            sum += plane[sourceY * width + min(originX + column * factor + dx, width - 1)]
                        }
                    }
                    block[row * 8 + column] = sum * weight
                }
            }
        }

        for mcuY in stride(from: 0, to: height, by: mcuSize) {
            for mcuX in stride(from: 0, to: width, by: mcuSize) {
                for blockRow in 0..<factor {
                    for blockColumn in 0..<factor {
                        fillLuma(x: mcuX + blockColumn * 8, y: mcuY + blockRow * 8)
                        transformAndQuantize(block, divisors: luminanceDivisors, into: &coefficients)
                        encodeBlock(coefficients, previousDC: &previousDC[0], dc: dcLuminance, ac: acLuminance, writer: &writer)
                    }
                }
                fillChroma(blueChroma, x: mcuX, y: mcuY)
                transformAndQuantize(block, divisors: chrominanceDivisors, into: &coefficients)
                encodeBlock(coefficients, previousDC: &previousDC[1], dc: dcChrominance, ac: acChrominance, writer: &writer)
                fillChroma(redChroma, x: mcuX, y: mcuY)
                transformAndQuantize(block, divisors: chrominanceDivisors, into: &coefficients)
                encodeBlock(coefficients, previousDC: &previousDC[2], dc: dcChrominance, ac: acChrominance, writer: &writer)
            }
        }
        writer.flush()
        output.append(contentsOf: writer.bytes)
        output.append(contentsOf: [0xff, 0xd9])
        return output
    }

    // MARK: - Tables (ITU-T T.81 Annex K)

    public static let zigzag: [Int] = [
        0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5,
        12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
        35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
        58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63
    ]

    public static let standardLuminance: [Int] = [
        16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55,
        14, 13, 16, 24, 40, 57, 69, 56, 14, 17, 22, 29, 51, 87, 80, 62,
        18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92,
        49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99
    ]

    public static let standardChrominance: [Int] = [
        17, 18, 24, 47, 99, 99, 99, 99, 18, 21, 26, 66, 99, 99, 99, 99,
        24, 26, 56, 99, 99, 99, 99, 99, 47, 66, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99
    ]

    /// libjpeg's `jpeg_quality_scaling` with baseline clamping; natural (row-major) order.
    public static func scaledTable(_ base: [Int], quality: Int) -> [Int] {
        let q = max(1, min(100, quality))
        let scale = q < 50 ? 5000 / q : 200 - q * 2
        return base.map { max(1, min(255, ($0 * scale + 50) / 100)) }
    }

    public struct HuffmanSpec {
        public let bits: [UInt8]   // number of codes of each length 1…16
        public let values: [UInt8]
        let codes: [UInt16]
        let lengths: [UInt8]

        init(bits: [UInt8], values: [UInt8]) {
            self.bits = bits
            self.values = values
            var codes = [UInt16](repeating: 0, count: 256)
            var lengths = [UInt8](repeating: 0, count: 256)
            var code: UInt16 = 0
            var index = 0
            for length in 1...16 {
                for _ in 0..<Int(bits[length - 1]) {
                    codes[Int(values[index])] = code
                    lengths[Int(values[index])] = UInt8(length)
                    code += 1
                    index += 1
                }
                code <<= 1
            }
            self.codes = codes
            self.lengths = lengths
        }
    }

    static let dcLuminance = HuffmanSpec(
        bits: [0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0],
        values: Array(UInt8(0)...11)
    )

    static let dcChrominance = HuffmanSpec(
        bits: [0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0],
        values: Array(UInt8(0)...11)
    )

    public static let acLuminance = HuffmanSpec(
        bits: [0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d],
        values: [
            0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
            0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08, 0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0,
            0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28,
            0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
            0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
            0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
            0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7,
            0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5,
            0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
            0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
            0xf9, 0xfa
        ]
    )

    public static let acChrominance = HuffmanSpec(
        bits: [0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77],
        values: [
            0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71,
            0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0,
            0x15, 0x62, 0x72, 0xd1, 0x0a, 0x16, 0x24, 0x34, 0xe1, 0x25, 0xf1, 0x17, 0x18, 0x19, 0x1a, 0x26,
            0x27, 0x28, 0x29, 0x2a, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
            0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
            0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
            0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5,
            0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3,
            0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda,
            0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
            0xf9, 0xfa
        ]
    )

    // MARK: - Headers

    private static func writeHeaders(
        into output: inout Data, width: Int, height: Int, luminance: [Int], chrominance: [Int], lumaSampling: UInt8
    ) {
        output.append(contentsOf: [0xff, 0xd8])
        // APP0 JFIF 1.01, no density units, 1:1 aspect, no thumbnail (as libjpeg writes it).
        output.append(contentsOf: [0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00])
        for (id, table) in [(0, luminance), (1, chrominance)] {
            output.append(contentsOf: [0xff, 0xdb, 0x00, 0x43, UInt8(id)])
            output.append(contentsOf: zigzag.map { UInt8(table[$0]) })
        }
        output.append(contentsOf: [
            0xff, 0xc0, 0x00, 0x11, 0x08,
            UInt8(height >> 8), UInt8(height & 0xff), UInt8(width >> 8), UInt8(width & 0xff),
            0x03, 0x01, lumaSampling, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01
        ])
        for (classAndID, spec) in [(0x00, dcLuminance), (0x10, acLuminance), (0x01, dcChrominance), (0x11, acChrominance)] {
            let length = 2 + 1 + 16 + spec.values.count
            output.append(contentsOf: [0xff, 0xc4, UInt8(length >> 8), UInt8(length & 0xff), UInt8(classAndID)])
            output.append(contentsOf: spec.bits)
            output.append(contentsOf: spec.values)
        }
        output.append(contentsOf: [0xff, 0xda, 0x00, 0x0c, 0x03, 0x01, 0x00, 0x02, 0x11, 0x03, 0x11, 0x00, 0x3f, 0x00])
    }

    // MARK: - Transform and entropy coding

    private static let cosines: [Float] = (0..<64).map { index in
        let x = index / 8, u = index % 8
        return Float(cos(Double(2 * x + 1) * Double(u) * .pi / 16))
    }

    private static func transformAndQuantize(_ block: [Float], divisors: [Float], into output: inout [Int]) {
        var rows = [Float](repeating: 0, count: 64)
        for y in 0..<8 {
            for u in 0..<8 {
                var sum: Float = 0
                for x in 0..<8 { sum += block[y * 8 + x] * cosines[x * 8 + u] }
                rows[y * 8 + u] = sum
            }
        }
        for v in 0..<8 {
            let cv: Float = v == 0 ? 0.707_106_77 : 1
            for u in 0..<8 {
                let cu: Float = u == 0 ? 0.707_106_77 : 1
                var sum: Float = 0
                for y in 0..<8 { sum += rows[y * 8 + u] * cosines[y * 8 + v] }
                let coefficient = 0.25 * cu * cv * sum
                output[v * 8 + u] = Int((coefficient / divisors[v * 8 + u]).rounded())
            }
        }
    }

    private static func encodeBlock(_ coefficients: [Int], previousDC: inout Int, dc: HuffmanSpec, ac: HuffmanSpec, writer: inout BitWriter) {
        let difference = coefficients[0] - previousDC
        previousDC = coefficients[0]
        let dcSize = magnitudeSize(difference)
        writer.write(dc.codes[dcSize], count: Int(dc.lengths[dcSize]))
        if dcSize > 0 { writer.write(magnitudeBits(difference, size: dcSize), count: dcSize) }

        var zeroRun = 0
        for index in 1..<64 {
            let value = coefficients[zigzag[index]]
            if value == 0 {
                zeroRun += 1
                continue
            }
            while zeroRun >= 16 {
                writer.write(ac.codes[0xf0], count: Int(ac.lengths[0xf0]))
                zeroRun -= 16
            }
            let size = magnitudeSize(value)
            let symbol = (zeroRun << 4) | size
            writer.write(ac.codes[symbol], count: Int(ac.lengths[symbol]))
            writer.write(magnitudeBits(value, size: size), count: size)
            zeroRun = 0
        }
        if zeroRun > 0 { writer.write(ac.codes[0x00], count: Int(ac.lengths[0x00])) }
    }

    private static func magnitudeSize(_ value: Int) -> Int {
        var magnitude = abs(value), size = 0
        while magnitude > 0 { magnitude >>= 1; size += 1 }
        return size
    }

    private static func magnitudeBits(_ value: Int, size: Int) -> UInt16 {
        UInt16(truncatingIfNeeded: value >= 0 ? value : value + (1 << size) - 1)
    }

    private struct BitWriter {
        var bytes: [UInt8] = []
        private var buffer: UInt32 = 0
        private var bufferedBits = 0

        mutating func write(_ bits: UInt16, count: Int) {
            guard count > 0 else { return }
            buffer = (buffer << UInt32(count)) | (UInt32(bits) & ((1 << UInt32(count)) - 1))
            bufferedBits += count
            while bufferedBits >= 8 {
                let byte = UInt8((buffer >> UInt32(bufferedBits - 8)) & 0xff)
                bytes.append(byte)
                if byte == 0xff { bytes.append(0) }
                bufferedBits -= 8
            }
            buffer &= (1 << UInt32(bufferedBits)) - 1
        }

        /// Pads the final byte with 1 bits, as the JPEG standard requires.
        mutating func flush() {
            if bufferedBits > 0 { write(0x7f, count: 8 - bufferedBits) }
        }
    }
}
