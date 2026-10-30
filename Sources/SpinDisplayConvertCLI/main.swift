import Foundation
import SpinDisplayCore
import SpinDisplayMedia

// Offline converter and inspector for FTLV files. It never contacts a fan.
//
//   SpinDisplayConvertCLI convert <input> <output.ftlv> [--size N] [--max-fps N] [--fit] [--zoom Z] [--center-x X] [--center-y Y] [--no-audio]
//                                 [--start S] [--end S] [--trim]
//   SpinDisplayConvertCLI inspect <file.ftlv> [--extract-frames DIR]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func value(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func inspect(_ path: String, extractTo directory: String?) {
    guard let data = FileManager.default.contents(atPath: path) else { fail("Cannot read \(path)") }
    let bytes = [UInt8](data)
    guard let contents = FTLVContents.parse(bytes) else { fail("Not a valid FTLV file: \(path)") }
    let info = contents.info
    print("magic: \(String(decoding: contents.magic.map { $0 < 32 ? UInt8(ascii: "?") : $0 }, as: UTF8.self)) (\(contents.magic.map { String(format: "%02X", $0) }.joined(separator: " ")))")
    print("version: \(info.version)  file: \(info.fileLength)  data: \(info.dataLength)  audio: \(info.audioLength)  index: \(info.indexLength)")
    print("frame duration: \(info.frameDuration) µs  frames: \(info.frameCount)  total: \(contents.totalSeconds) s")
    print("video blocks: \(contents.videoBlocks.count)  audio block: \(contents.audioBlock.map { "\($0.length) bytes" } ?? "none")")
    var badFrames = 0
    for (index, block) in contents.videoBlocks.enumerated() {
        let frame = bytes[block.offset..<(block.offset + block.length)]
        if frame.prefix(2) != [0xff, 0xd8] || frame.suffix(2) != [0xff, 0xd9] { badFrames += 1 }
        if let directory {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(String(format: "frame_%05d.jpg", index + 1))
            try? Data(frame).write(to: url)
        }
    }
    print(badFrames == 0 ? "all video blocks are complete JPEGs" : "\(badFrames) video block(s) are not complete JPEGs")
    if contents.videoBlocks.count != info.frameCount { print("warning: header frame count differs from video block count") }
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "inspect":
    guard arguments.count >= 2 else { fail("usage: inspect <file.ftlv> [--extract-frames DIR]") }
    inspect(arguments[1], extractTo: value(after: "--extract-frames", in: arguments))
case "convert":
    guard arguments.count >= 3 else { fail("usage: convert <input> <output.ftlv> [options]") }
    let input = URL(fileURLWithPath: arguments[1])
    let output = URL(fileURLWithPath: arguments[2])
    let target = MediaConverter.Target(
        imageSize: Int(value(after: "--size", in: arguments) ?? "") ?? 672,
        maxFPS: Int(value(after: "--max-fps", in: arguments) ?? "") ?? 20
    )
    let options = MediaConverter.Options(
        crop: MediaConverter.Crop(
            framing: arguments.contains("--fit") ? .fit : .fill,
            zoom: Double(value(after: "--zoom", in: arguments) ?? "") ?? 1,
            centerX: Double(value(after: "--center-x", in: arguments) ?? "") ?? 0.5,
            centerY: Double(value(after: "--center-y", in: arguments) ?? "") ?? 0.5
        ),
        includeAudio: !arguments.contains("--no-audio"),
        startSecond: Int(value(after: "--start", in: arguments) ?? "") ?? 0,
        endSecond: Int(value(after: "--end", in: arguments) ?? ""),
        holdLastFrame: !arguments.contains("--trim")
    )
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        do {
            let kind = try await MediaConverter.inspect(input)
            print("input: \(kind)")
            let started = Date()
            let result = try await MediaConverter.convert(
                input, kind: kind, target: target, options: options, output: output,
                isCancelled: { false }, progress: { _, _ in }
            )
            print("wrote \(result.url.path): \(result.frameCount) frame(s), fps \(result.fps.map(String.init) ?? "-"), audio \(result.hasAudio) in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
            inspect(output.path, extractTo: nil)
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
        semaphore.signal()
    }
    semaphore.wait()
default:
    fail("usage: SpinDisplayConvertCLI convert|inspect …")
}
