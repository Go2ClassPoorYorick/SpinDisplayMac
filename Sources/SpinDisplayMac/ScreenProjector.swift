import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import SpinDisplayMedia

/// What the projector captures.
enum ProjectionSource: Equatable {
    /// A square of a display, in display-local points with a top-left origin.
    case displayArea(displayID: CGDirectDisplayID, rect: CGRect)
    /// One window (followed wherever it moves), framed into the circle like the media converter.
    case window(windowID: CGWindowID, crop: MediaConverter.Crop)
}

/// Captures for screen projection, following the original `ProjectionWindow`: frames are scaled to the
/// fan's image size, encoded as 4:2:0 JPEG at quality 30, and sent as fast as the fan accepts them.
/// The original always captured a centered square of the primary screen (`captureRect`); a display
/// area, window, and size can now be chosen.
final class ScreenProjector: NSObject, SCStreamOutput, SCStreamDelegate {
    var onFrame: ((Data) -> Void)?
    var onPreview: ((CGImage) -> Void)?
    var onStopped: ((String) -> Void)?

    private let imageSize: Int
    private let maxFPS: Int
    /// Content-type-3 fans receive mold JPEGs (original `JpgBinTool.toBin`, quality 90).
    private let mold: MoldTranscoder?
    private let sampleQueue = DispatchQueue(label: "SpinDisplay.projection.capture")
    private let stateLock = NSLock()
    private var stream: SCStream?
    private var source: ProjectionSource?
    private var lastPreview = Date.distantPast

    init(imageSize: Int, maxFPS: Int, mold: MoldTranscoder? = nil) {
        self.imageSize = imageSize
        self.maxFPS = max(1, maxFPS)
        self.mold = mold
    }

    /// The original captures this square of the primary screen: its shorter side, capped at 1024.
    static func captureRect(screenWidth: CGFloat, screenHeight: CGFloat) -> CGRect {
        let side = min(min(screenWidth, screenHeight), 1024)
        return CGRect(x: (screenWidth - side) / 2, y: (screenHeight - side) / 2, width: side, height: side)
    }

    func start(source: ProjectionSource, excludingWindowIDs: [CGWindowID]) async throws {
        let (filter, configuration) = try await Self.makeFilterAndConfiguration(
            for: source, imageSize: imageSize, maxFPS: maxFPS, excludingWindowIDs: excludingWindowIDs
        )
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        stateLock.withLock {
            self.stream = stream
            self.source = source
        }
    }

    /// Applies a new source while running. Moving or resizing within the same display or window only
    /// updates the configuration; changing display or window also swaps the content filter.
    /// `forceFilter` re-applies the content filter, for example to exclude a newly shown overlay window.
    func update(source newSource: ProjectionSource, excludingWindowIDs: [CGWindowID], forceFilter: Bool = false) async throws {
        let (stream, oldSource) = stateLock.withLock { (self.stream, self.source) }
        guard let stream, forceFilter || newSource != oldSource else { return }
        stateLock.withLock { self.source = newSource }
        let sameTarget: Bool
        switch (oldSource, newSource) {
        case (.displayArea(let a, _)?, .displayArea(let b, _)): sameTarget = a == b
        case (.window(let a, _)?, .window(let b, _)): sameTarget = a == b
        default: sameTarget = false
        }
        if case .window = newSource, sameTarget, !forceFilter { return }  // window crops are applied per frame
        let (filter, configuration) = try await Self.makeFilterAndConfiguration(
            for: newSource, imageSize: imageSize, maxFPS: maxFPS, excludingWindowIDs: excludingWindowIDs
        )
        if !sameTarget || forceFilter { try await stream.updateContentFilter(filter) }
        try await stream.updateConfiguration(configuration)
    }

    func stop() {
        let stream = stateLock.withLock { () -> SCStream? in
            defer { self.stream = nil }
            return self.stream
        }
        guard let stream else { return }
        Task { try? await stream.stopCapture() }
    }

    private static func makeFilterAndConfiguration(
        for source: ProjectionSource,
        imageSize: Int,
        maxFPS: Int,
        excludingWindowIDs: [CGWindowID]
    ) async throws -> (SCContentFilter, SCStreamConfiguration) {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw ProjectionError.permissionDenied
        }
        let configuration = SCStreamConfiguration()
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(maxFPS))
        configuration.queueDepth = 3
        configuration.showsCursor = true

        switch source {
        case .displayArea(let displayID, let rect):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
                throw ProjectionError.noDisplay
            }
            let excluded = content.windows.filter { excludingWindowIDs.contains($0.windowID) }
            configuration.sourceRect = rect
            configuration.width = imageSize
            configuration.height = imageSize
            return (SCContentFilter(display: display, excludingWindows: excluded), configuration)

        case .window(let windowID, _):
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw ProjectionError.windowUnavailable
            }
            // Capture the whole window at up to twice the fan's size; the crop is rendered per frame.
            let longest = max(window.frame.width, window.frame.height, 1)
            let scale = min(2, CGFloat(imageSize * 2) / longest)  // Retina detail, at most 2× the fan's size
            configuration.width = max(16, Int(window.frame.width * scale))
            configuration.height = max(16, Int(window.frame.height * scale))
            return (SCContentFilter(desktopIndependentWindow: window), configuration)
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusValue = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusValue) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let captured = Self.image(from: pixelBuffer) else {
            return
        }
        let source = stateLock.withLock { self.source }
        let frame: CGImage
        switch source {
        case .window(_, let crop)?:
            guard let rendered = try? MediaConverter.render(captured, size: imageSize, crop: crop) else { return }
            frame = rendered
        default:
            frame = captured
        }
        guard let rgba = Self.rgbaPixels(of: frame) else { return }
        if let mold {
            onFrame?(mold.jpeg(rgba: rgba, width: frame.width, height: frame.height, quality: 90))
        } else {
            onFrame?(BaselineJPEGEncoder.encode(rgba: rgba, width: frame.width, height: frame.height, quality: 30, subsampling: .s420))
        }
        if Date().timeIntervalSince(lastPreview) > 0.25 {
            lastPreview = Date()
            onPreview?(frame)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        stateLock.withLock { self.stream = nil }
        onStopped?("Screen capture stopped: \(error.localizedDescription)")
    }

    private static func image(from pixelBuffer: CVPixelBuffer) -> CGImage? {
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

    private static func rgbaPixels(of image: CGImage) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return drawn ? pixels : nil
    }

    enum ProjectionError: LocalizedError {
        case permissionDenied
        case noDisplay
        case windowUnavailable

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Screen capture is not allowed. Enable SpinDisplay in System Settings > Privacy & Security > Screen & System Audio Recording, then try again."
            case .noDisplay:
                return "No display is available to capture."
            case .windowUnavailable:
                return "The selected window is no longer available. Refresh the window list."
            }
        }
    }
}

/// Displays and windows that can be projected.
enum ProjectionSources {
    struct Display: Identifiable, Hashable {
        let id: CGDirectDisplayID
        let name: String
        let size: CGSize
    }

    struct Window: Identifiable, Hashable {
        let id: CGWindowID
        let title: String
    }

    static func load() async throws -> (displays: [Display], windows: [Window]) {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            throw ScreenProjector.ProjectionError.permissionDenied
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let displays = content.displays.map { display in
            Display(id: display.displayID, name: screenName(for: display.displayID), size: CGSize(width: display.width, height: display.height))
        }
        let windows = content.windows
            .filter { $0.windowLayer == 0 && $0.frame.width > 80 && $0.frame.height > 80 }
            .filter { $0.owningApplication?.processID != ownPID }
            .map { window -> Window in
                let app = window.owningApplication?.applicationName ?? "Window"
                let title = window.title.map { $0.isEmpty ? app : "\(app) — \($0)" } ?? app
                return Window(id: window.windowID, title: title)
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        return (displays, windows)
    }

    private static func screenName(for displayID: CGDirectDisplayID) -> String {
        let screen = NSScreenLookup.screen(for: displayID)
        let name = screen?.localizedName ?? "Display \(displayID)"
        return displayID == CGMainDisplayID() ? "\(name) (main)" : name
    }
}
