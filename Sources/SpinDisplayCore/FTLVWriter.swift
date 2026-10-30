import Foundation

/// Streams an FTLV container to disk, following the original `F20AD.Utils.FTLV` class and
/// `TcpServer.ConvertToFTLVWork`:
///
/// - a 512-byte header area (48 meaningful bytes, the rest zero), written last;
/// - video frames (JPEG data), each zero-padded to a multiple of 4 bytes;
/// - an optional audio block (8-bit mono PCM without its WAV header), also padded;
/// - an index: 8 bytes `A5 00 00 00 00 00 00 00`, then one `(offset, unpadded length)`
///   little-endian pair per block, audio included.
///
/// The original keeps a 16-byte per-block header struct but never writes it, so neither does this.
public final class FTLVWriter {
    public static let headerLength = 512
    public static let videoFlag: UInt8 = 0x22
    public static let audioFlag: UInt8 = 0x11
    /// Duration the original assigns to a still image frame (10 seconds, in microseconds).
    public static let stillImageFrameDuration = 10_000_000

    public enum Magic: Equatable, Sendable {
        /// `"FTLV"`, used unless the fan reports content type 3.
        case standard
        /// `"FTL"` followed by the device-type byte, used when the fan reports content type 3.
        case deviceTyped(UInt8)
    }

    public enum WriterError: Error {
        case alreadyFinished
        case fileTooLarge
    }

    private struct IndexItem {
        let offset: Int
        let length: Int
    }

    private let handle: FileHandle
    private let magic: Magic
    private let frameDuration: Int
    private var frameCount = 0
    private var offset = FTLVWriter.headerLength
    private var audioLength = 0
    private var totalVideoDuration = 0
    private var index: [IndexItem] = []
    private var finished = false

    /// - Parameters:
    ///   - frameDuration: the header's per-frame duration in microseconds (`1_000_000 / fps` for video,
    ///     `stillImageFrameDuration` for a still image).
    /// The header's frame count is the number of video frames appended.
    public init(url: URL, magic: Magic, frameDuration: Int) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(count: Self.headerLength))
        self.magic = magic
        self.frameDuration = frameDuration
    }

    deinit {
        try? handle.close()
    }

    /// Appends one video frame; `duration` is in microseconds.
    public func appendVideoFrame(_ jpeg: Data, duration: Int) throws {
        try appendBlock(jpeg)
        frameCount += 1
        totalVideoDuration += duration
    }

    /// Appends the audio block: raw unsigned 8-bit mono PCM samples at 44.1 kHz.
    public func appendAudio(_ pcm: Data) throws {
        let padded = Self.paddedLength(pcm.count)
        try appendBlock(pcm)
        audioLength += padded
    }

    /// Writes the index and the header, closes the file, and returns the 48 header bytes.
    @discardableResult
    public func finish() throws -> [UInt8] {
        guard !finished else { throw WriterError.alreadyFinished }
        finished = true
        let indexData = indexBytes()
        try handle.write(contentsOf: Data(indexData))
        let header = headerBytes(indexLength: indexData.count)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data(header))
        try handle.close()
        return header
    }

    public static func paddedLength(_ length: Int) -> Int {
        length % 4 == 0 ? length : (length / 4 + 1) * 4
    }

    private func appendBlock(_ data: Data) throws {
        guard !finished else { throw WriterError.alreadyFinished }
        let padded = Self.paddedLength(data.count)
        guard offset + padded + (index.count + 2) * 8 <= Int(Int32.max) else { throw WriterError.fileTooLarge }
        try handle.write(contentsOf: data)
        if padded > data.count {
            try handle.write(contentsOf: Data(count: padded - data.count))
        }
        index.append(IndexItem(offset: offset, length: data.count))
        offset += padded
    }

    private func indexBytes() -> [UInt8] {
        var bytes: [UInt8] = [0xa5, 0, 0, 0, 0, 0, 0, 0]
        for item in index {
            bytes += Self.int32Bytes(item.offset) + Self.int32Bytes(item.length)
        }
        return bytes
    }

    private func headerBytes(indexLength: Int) -> [UInt8] {
        var header: [UInt8]
        switch magic {
        case .standard:
            header = Array("FTLV".utf8)
        case .deviceTyped(let deviceType):
            header = Array("FTL".utf8) + [deviceType]
        }
        header += [1, 0, 0, 0]  // version 1, three reserved bytes
        header += Self.int32Bytes(offset + indexLength)
        header += Self.int32Bytes(Self.headerLength)
        header += Self.int32Bytes(offset - Self.headerLength - audioLength)
        header += Self.int32Bytes(audioLength)
        header += Self.int32Bytes(indexLength)
        header += [UInt8](repeating: 0, count: 8)
        header += Self.int32Bytes(frameDuration)
        header += Self.int32Bytes(frameCount)
        header += Self.int32Bytes(totalVideoDuration / 1_000_000)
        return header
    }

    private static func int32Bytes(_ value: Int) -> [UInt8] {
        let raw = UInt32(truncatingIfNeeded: value)
        return [UInt8(raw & 0xff), UInt8((raw >> 8) & 0xff), UInt8((raw >> 16) & 0xff), UInt8(raw >> 24)]
    }
}

/// Timing rules from the original `SendWindow.Send_File` and `TcpServer.SendFile`.
public enum FTLVTiming {
    /// The original caps a video's integer fps at the fan's `max_fps` and falls back to 20 outside 1…60.
    public static func videoFPS(sourceFPS: Double, maxFPS: Int) -> Int {
        let source = sourceFPS.isFinite ? Int(sourceFPS) : 0
        let fps = min(source, maxFPS > 0 ? maxFPS : 20)
        return (1...60).contains(fps) ? fps : 20
    }

    /// The original stores milliseconds per frame, then recovers fps as `1000 / ms`.
    public static func effectiveFPS(_ fps: Int) -> Int {
        let milliseconds = 1000 / max(1, fps)
        return 1000 / max(1, milliseconds)
    }

    public static func frameDuration(fps: Int) -> Int {
        1_000_000 / max(1, effectiveFPS(fps))
    }
}

/// Reads back an FTLV file's header and index for verification.
public struct FTLVContents: Sendable {
    public struct Block: Equatable, Sendable {
        public let offset: Int
        public let length: Int

        public init(offset: Int, length: Int) {
            self.offset = offset
            self.length = length
        }
    }

    public let info: FTLVFileInfo
    public let magic: [UInt8]
    public let totalSeconds: Int
    public let blocks: [Block]

    /// Video frame blocks; the audio block, if any, is the last block and lies inside the audio area.
    public var videoBlocks: [Block] {
        let dataEnd = info.headerLength + info.dataLength
        return blocks.filter { $0.offset < dataEnd }
    }

    public var audioBlock: Block? {
        let dataEnd = info.headerLength + info.dataLength
        return blocks.first { $0.offset >= dataEnd }
    }

    public static func parse(_ data: [UInt8]) -> FTLVContents? {
        guard let info = FTLVFileInfo.parse(header: Array(data.prefix(512)), actualFileLength: data.count) else { return nil }
        let indexStart = info.headerLength + info.dataLength + info.audioLength
        guard data[indexStart] == 0xa5, (info.indexLength - 8) % 8 == 0 else { return nil }
        func int32(_ offset: Int) -> Int {
            Int(UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24)
        }
        var blocks: [Block] = []
        var cursor = indexStart + 8
        while cursor + 8 <= indexStart + info.indexLength {
            let block = Block(offset: int32(cursor), length: int32(cursor + 4))
            guard block.offset >= info.headerLength, block.offset + block.length <= indexStart else { return nil }
            blocks.append(block)
            cursor += 8
        }
        return FTLVContents(info: info, magic: Array(data[0..<4]), totalSeconds: int32(44), blocks: blocks)
    }
}
