#if os(iOS) || os(macOS)
import Foundation
import AVFoundation

enum AudioSlicer {
    // Lossless local PCM slices; no network, recognizer or codec service involved.
    static func extract(_ clip: Clip, range: Range<Double>, root: URL) throws -> AudioSlice {
        guard range.lowerBound >= 0, range.upperBound <= clip.duration, !range.isEmpty,
              !(try RetentionDisk.deletedIDs(from: root)).contains(clip.id) else { throw ArchiveFailure.invalidClip }
        var input = root.appendingPathComponent(clip.file)
        var origin = 0.0
        if FileManager.default.fileExists(atPath: input.path) {
            guard AudioVault.hash(try Data(contentsOf: input)) == clip.digest else { throw ArchiveFailure.invalidClip }
        } else {
            // A narrower favorite/Mark can be re-cut after the original has expired.
            guard let slice = try AudioVault.load(root).slices.first(where: {
                $0.clipID == clip.id && $0.sourceDigest == clip.digest && $0.start <= range.lowerBound && $0.end >= range.upperBound && AudioVault.verified($0, root: root)
            }) else { throw ArchiveFailure.invalidClip }
            input = root.appendingPathComponent(slice.file); origin = slice.start
        }
        let reader = try AVAudioFile(forReading: input, commonFormat: .pcmFormatFloat32, interleaved: false)
        let rate = reader.processingFormat.sampleRate
        let start = AVAudioFramePosition(floor((range.lowerBound - origin) * rate))
        let end = min(reader.length, AVAudioFramePosition(ceil((range.upperBound - origin) * rate)))
        guard end > start, Double(end) / rate >= range.upperBound - origin - 1 / rate,
              let buffer = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: AVAudioFrameCount(end - start)) else { throw ArchiveFailure.invalidClip }
        reader.framePosition = start
        let wanted = AVAudioFrameCount(end - start)
        var written: AVAudioFrameCount = 0
        while written < wanted {
            guard let part = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: wanted - written) else { throw ArchiveFailure.invalidClip }
            try reader.read(into: part, frameCount: wanted - written)
            guard part.frameLength > 0, let source = part.floatChannelData, let target = buffer.floatChannelData else { throw ArchiveFailure.invalidClip }
            for channel in 0..<Int(reader.processingFormat.channelCount) {
                target[channel].advanced(by: Int(written)).update(from: source[channel], count: Int(part.frameLength))
            }
            written += part.frameLength
        }
        buffer.frameLength = written
        let id = UUID().uuidString
        let output = root.appendingPathComponent("retained-\(id).caf")
        do {
            // Close writer before reopening and publishing the digest.
            do { let writer = try AVAudioFile(forWriting: output, settings: reader.processingFormat.settings); try writer.write(from: buffer) }
            let check = try AVAudioFile(forReading: output)
            guard check.length == AVAudioFramePosition(buffer.frameLength) else { throw ArchiveFailure.invalidClip }
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: output.path)
            #endif
            return AudioSlice(id: id, clipID: clip.id, start: range.lowerBound, end: range.upperBound,
                              digest: AudioVault.hash(try Data(contentsOf: output)), sourceDigest: clip.digest)
        } catch { try? FileManager.default.removeItem(at: output); throw error }
    }
}
#endif
