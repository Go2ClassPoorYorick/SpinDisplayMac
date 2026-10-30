import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import SpinDisplayCore
import UniformTypeIdentifiers

/// Converts images, animated GIFs, and videos to FTLV following the original client's
/// non-transcoding path (`DrawTool.ImageClip` + `TcpServer.ConvertToFTLVWork`): each frame is the
/// selected square of the source drawn on black, clipped to a circle 9 px larger than the frame on
/// every side, and saved as a quality-80 JPEG at the fan's reported image size.
public enum MediaConverter {
    public enum Framing: String, CaseIterable, Identifiable, Sendable {
        case fill
        case fit
        public var id: String { rawValue }
    }

    public enum MediaKind: Equatable, Sendable {
        case image
        case animatedImage(frameCount: Int, duration: Double)
        case video(duration: Double, sourceFPS: Double, hasAudio: Bool)
    }

    public struct Target: Sendable {
        public var imageSize: Int
        public var maxFPS: Int

        public init(imageSize: Int, maxFPS: Int) {
            self.imageSize = imageSize
            self.maxFPS = maxFPS
        }

        public static let generic = Target(imageSize: 672, maxFPS: 20)
    }

    public struct Options: Sendable {
        public var framing: Framing = .fill
        public var includeAudio = true
        public var startSecond = 0
        public var endSecond: Int?
        /// Round a video's length up to whole seconds and repeat its last frame, instead of the original
        /// client's behavior of rounding down and dropping the remainder.
        public var holdLastFrame = true

        public init(
            framing: Framing = .fill,
            includeAudio: Bool = true,
            startSecond: Int = 0,
            endSecond: Int? = nil,
            holdLastFrame: Bool = true
        ) {
            self.framing = framing
            self.includeAudio = includeAudio
            self.startSecond = startSecond
            self.endSecond = endSecond
            self.holdLastFrame = holdLastFrame
        }
    }

    public struct Result: Sendable {
        public let url: URL
        public let frameCount: Int
        public let fps: Int?
        public let hasAudio: Bool
    }

    public enum ConversionError: LocalizedError {
        case unreadable
        case noFrames
        case cancelled
        case encodingFailed

        public var errorDescription: String? {
            switch self {
            case .unreadable: return "The file could not be read as an image or video."
            case .noFrames: return "No frames could be decoded from the selected range."
            case .cancelled: return "Conversion was cancelled."
            case .encodingFailed: return "A frame could not be encoded as JPEG."
            }
        }
    }

    /// Whole seconds a video can span: rounded down like the original, or up when holding the last frame.
    /// The small tolerance keeps container rounding (for example 7.0004 s) from adding a held second.
    public static func availableSeconds(duration: Double, holdLastFrame: Bool) -> Int {
        guard duration.isFinite, duration > 0 else { return 1 }
        let seconds = holdLastFrame ? (duration - 0.01).rounded(.up) : duration.rounded(.down)
        return max(1, Int(seconds))
    }

    /// The original only converts this way when the fan does not need its LED transcoding ("mold") path.
    public static func unsupportedReason(deviceType: UInt8?, contentType: UInt8?) -> String? {
        if let deviceType, [25, 26].contains(deviceType) {
            return "Fan type \(deviceType) needs the original's LED transcoding, which is not implemented yet."
        }
        if contentType == 3 {
            return "This fan reports content type 3, which needs the original's LED transcoding (not implemented yet)."
        }
        return nil
    }

    public static func inspect(_ url: URL) async throws -> MediaKind {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let type = CGImageSourceGetType(source) as String?,
           UTType(type)?.conforms(to: .image) == true {
            let count = CGImageSourceGetCount(source)
            guard count > 0 else { throw ConversionError.unreadable }
            if count == 1 { return .image }
            let duration = frameDelays(source).reduce(0, +)
            return .animatedImage(frameCount: count, duration: duration)
        }
        let asset = AVURLAsset(url: url)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ConversionError.unreadable
        }
        let duration = try await asset.load(.duration).seconds
        let fps = try await videoTrack.load(.nominalFrameRate)
        let hasAudio = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
        return .video(duration: duration, sourceFPS: Double(fps), hasAudio: hasAudio)
    }

    /// Renders the first frame for preview, using the same pipeline as conversion.
    public static func preview(_ url: URL, kind: MediaKind, target: Target, framing: Framing, startSecond: Int) async throws -> CGImage {
        switch kind {
        case .image, .animatedImage:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw ConversionError.unreadable
            }
            return try render(image, size: target.imageSize, framing: framing)
        case .video:
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            let image = try await generator.image(at: CMTime(seconds: Double(startSecond), preferredTimescale: 600)).image
            return try render(image, size: target.imageSize, framing: framing)
        }
    }

    public static func convert(
        _ url: URL,
        kind: MediaKind,
        target: Target,
        options: Options,
        output: URL,
        isCancelled: @escaping @Sendable () -> Bool,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> Result {
        switch kind {
        case .image:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw ConversionError.unreadable
            }
            let writer = try FTLVWriter(url: output, magic: .standard, frameDuration: FTLVWriter.stillImageFrameDuration)
            try writer.appendVideoFrame(try jpeg(render(image, size: target.imageSize, framing: options.framing)),
                                        duration: FTLVWriter.stillImageFrameDuration)
            try writer.finish()
            progress(1, "Image converted.")
            return Result(url: output, frameCount: 1, fps: nil, hasAudio: false)

        case .animatedImage(_, let duration):
            return try convertAnimatedImage(url, duration: duration, target: target, options: options,
                                            output: output, isCancelled: isCancelled, progress: progress)

        case .video(let duration, let sourceFPS, let hasAudio):
            return try await convertVideo(url, duration: duration, sourceFPS: sourceFPS, hasAudio: hasAudio,
                                          target: target, options: options, output: output,
                                          isCancelled: isCancelled, progress: progress)
        }
    }

    // MARK: - Animated images

    private static func frameDelays(_ source: CGImageSource) -> [Double] {
        (0..<CGImageSourceGetCount(source)).map { index in
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let containers = [kCGImagePropertyGIFDictionary, kCGImagePropertyPNGDictionary, kCGImagePropertyHEICSDictionary]
            for key in containers {
                guard let dictionary = properties?[key] as? [CFString: Any] else { continue }
                let unclamped = dictionary[kCGImagePropertyGIFUnclampedDelayTime] as? Double
                    ?? dictionary[kCGImagePropertyAPNGUnclampedDelayTime] as? Double
                let delay = (unclamped ?? 0) > 0.0
                    ? unclamped!
                    : (dictionary[kCGImagePropertyGIFDelayTime] as? Double ?? dictionary[kCGImagePropertyAPNGDelayTime] as? Double ?? 0)
                // Browsers treat very short GIF delays as 0.1 s; match that so timing looks familiar.
                return delay < 0.02 ? 0.1 : delay
            }
            return 0.1
        }
    }

    private static func convertAnimatedImage(
        _ url: URL,
        duration: Double,
        target: Target,
        options: Options,
        output: URL,
        isCancelled: () -> Bool,
        progress: (Double, String) -> Void
    ) throws -> Result {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw ConversionError.unreadable }
        let delays = frameDelays(source)
        let total = max(duration, 0.1)
        let averageDelay = total / Double(max(1, delays.count))
        let fps = FTLVTiming.videoFPS(sourceFPS: (1 / averageDelay).rounded(), maxFPS: target.maxFPS)
        let effectiveFPS = FTLVTiming.effectiveFPS(fps)
        let frameDuration = FTLVTiming.frameDuration(fps: fps)
        let exactFrames = total * Double(effectiveFPS)
        let outputFrames = max(1, Int(options.holdLastFrame ? (exactFrames - 0.01).rounded(.up) : exactFrames))

        var starts: [Double] = []
        var elapsed = 0.0
        for delay in delays {
            starts.append(elapsed)
            elapsed += delay
        }

        let writer = try FTLVWriter(url: output, magic: .standard, frameDuration: frameDuration)
        var cachedIndex = -1
        var cachedJPEG = Data()
        for frame in 0..<outputFrames {
            if isCancelled() { throw ConversionError.cancelled }
            let time = Double(frame) / Double(effectiveFPS)
            let sourceIndex = max(0, (starts.lastIndex { $0 <= time } ?? 0))
            if sourceIndex != cachedIndex {
                guard let image = CGImageSourceCreateImageAtIndex(source, sourceIndex, nil) else { throw ConversionError.unreadable }
                cachedJPEG = try jpeg(render(image, size: target.imageSize, framing: options.framing))
                cachedIndex = sourceIndex
            }
            try writer.appendVideoFrame(cachedJPEG, duration: frameDuration)
            progress(Double(frame + 1) / Double(outputFrames), "Converting frame \(frame + 1) of \(outputFrames)…")
        }
        try writer.finish()
        return Result(url: output, frameCount: outputFrames, fps: effectiveFPS, hasAudio: false)
    }

    // MARK: - Video

    private static func convertVideo(
        _ url: URL,
        duration: Double,
        sourceFPS: Double,
        hasAudio: Bool,
        target: Target,
        options: Options,
        output: URL,
        isCancelled: @escaping () -> Bool,
        progress: @escaping (Double, String) -> Void
    ) async throws -> Result {
        let asset = AVURLAsset(url: url)
        let fps = FTLVTiming.videoFPS(sourceFPS: sourceFPS, maxFPS: target.maxFPS)
        let effectiveFPS = FTLVTiming.effectiveFPS(fps)
        let frameDuration = FTLVTiming.frameDuration(fps: fps)

        // The original works in whole seconds and expects (end - start) * fps frames. Holding the last
        // frame rounds the length up; frames past the end of the video repeat its final frame below.
        let wholeSeconds = availableSeconds(duration: duration, holdLastFrame: options.holdLastFrame)
        let start = max(0, min(options.startSecond, wholeSeconds - 1))
        let end = max(start + 1, min(options.endSecond ?? wholeSeconds, wholeSeconds))
        let expectedFrames = (end - start) * effectiveFPS
        // AVAssetReader rejects ranges past the asset's end, so read only real media; frames beyond it
        // are filled by repeating the last decoded frame.
        let range = CMTimeRange(
            start: CMTime(seconds: Double(start), preferredTimescale: 600),
            end: CMTime(seconds: min(Double(end), duration), preferredTimescale: 600)
        )

        // The composition applies the track's rotation. It still delivers every source frame (it ignores a
        // lower frameDuration), so frames are resampled to the target rate by presentation time below.
        let composition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: videoTracks,
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        videoOutput.videoComposition = composition
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)
        guard reader.startReading() else { throw reader.error ?? ConversionError.unreadable }

        let writer = try FTLVWriter(url: output, magic: .standard, frameDuration: frameDuration)
        var written = 0
        // Output frame k shows the latest source frame presented at or before start + k / fps.
        var current: (image: CGImage, jpeg: Data?)?
        func emitCurrent() throws {
            guard var frame = current else { return }
            if frame.jpeg == nil {
                frame.jpeg = try jpeg(render(frame.image, size: target.imageSize, framing: options.framing))
                current = frame
            }
            try writer.appendVideoFrame(frame.jpeg!, duration: frameDuration)
            written += 1
            progress(Double(written) / Double(expectedFrames) * 0.95, "Converting frame \(written) of \(expectedFrames)…")
        }
        func targetTime(_ index: Int) -> Double { Double(start) + Double(index) / Double(effectiveFPS) }

        while written < expectedFrames, let sample = videoOutput.copyNextSampleBuffer() {
            if isCancelled() {
                reader.cancelReading()
                throw ConversionError.cancelled
            }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample),
                  let image = cgImage(from: pixelBuffer) else { continue }
            let presentation = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            // Output times before this sample still show the previous source frame.
            while written < expectedFrames, current != nil, targetTime(written) < presentation - 0.000_1 {
                try emitCurrent()
            }
            current = (image, nil)
        }
        if reader.status == .failed { throw reader.error ?? ConversionError.unreadable }
        guard current != nil else { throw ConversionError.noFrames }
        // The remaining output times show the final source frame. Normally that is the frame on screen at
        // the end of the range; when the length was rounded up, it also holds that frame to the last second.
        while written < expectedFrames {
            if isCancelled() { throw ConversionError.cancelled }
            try emitCurrent()
        }

        var includedAudio = false
        if options.includeAudio, hasAudio, written > 1 {
            progress(0.96, "Extracting audio…")
            let pcm = try await audioPCM(asset: asset, range: range)
            if !pcm.isEmpty {
                try writer.appendAudio(pcm)
                includedAudio = true
            }
        }
        try writer.finish()
        progress(1, "Video converted.")
        return Result(url: output, frameCount: written, fps: effectiveFPS, hasAudio: includedAudio)
    }

    /// The original resamples audio to 44.1 kHz mono unsigned 8-bit PCM (`VideoStreamDecoder.extractAudio`).
    private static func audioPCM(asset: AVAsset, range: CMTimeRange) async throws -> Data {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return Data() }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ConversionError.unreadable }
        var pcm = Data()
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var bytes = [UInt8](repeating: 0, count: length)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &bytes)
            pcm.append(contentsOf: pcm16ToUnsigned8(bytes))
        }
        if reader.status == .failed { throw reader.error ?? ConversionError.unreadable }
        return pcm
    }

    /// Signed 16-bit little-endian samples to unsigned 8-bit, as FFmpeg's S16 → U8 conversion does.
    public static func pcm16ToUnsigned8(_ bytes: [UInt8]) -> [UInt8] {
        stride(from: 0, to: bytes.count - 1, by: 2).map { index in
            let sample = Int16(bitPattern: UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8))
            return UInt8(truncatingIfNeeded: (Int(sample) >> 8) + 128)
        }
    }

    // MARK: - Frame rendering

    private static func cgImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer),
              let context = CGContext(
                data: base,
                width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
              ) else {
            return nil
        }
        return context.makeImage()
    }

    /// The square region of the source that maps onto the fan's circle.
    public static func cropSquare(width: Int, height: Int, framing: Framing) -> CGRect {
        let w = CGFloat(width), h = CGFloat(height)
        let side = framing == .fill ? min(w, h) : max(w, h)
        return CGRect(x: (w - side) / 2, y: (h - side) / 2, width: side, height: side)
    }

    public static func render(_ image: CGImage, size: Int, framing: Framing) throws -> CGImage {
        guard let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw ConversionError.encodingFailed
        }
        let side = CGFloat(size)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.interpolationQuality = .high
        context.addEllipse(in: CGRect(x: -9, y: -9, width: side + 18, height: side + 18))
        context.clip()

        let crop = cropSquare(width: image.width, height: image.height, framing: framing)
        let scale = side / crop.width
        // CoreGraphics has a bottom-left origin; the crop rectangle is symmetric, so centering is identical.
        context.draw(image, in: CGRect(
            x: -crop.minX * scale,
            y: -crop.minY * scale,
            width: CGFloat(image.width) * scale,
            height: CGFloat(image.height) * scale
        ))
        guard let result = context.makeImage() else { throw ConversionError.encodingFailed }
        return result
    }

    /// Encodes like the original's libjpeg-turbo call: baseline, 4:4:4, quality 80, no restart markers.
    public static func jpeg(_ image: CGImage) throws -> Data {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw ConversionError.encodingFailed }
        return BaselineJPEGEncoder.encode(rgba: pixels, width: width, height: height, quality: 80)
    }
}
