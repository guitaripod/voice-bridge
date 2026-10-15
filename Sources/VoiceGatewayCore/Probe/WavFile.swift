import Foundation
import VoiceKit

public enum WavError: Error, CustomStringConvertible {
    case unreadable(String, String)
    case notWave(String)
    case unsupported(String, String)
    case noAudio(String)

    public var description: String {
        switch self {
        case .unreadable(let name, let why): "\(name): cannot read the file (\(why))."
        case .notWave(let name): "\(name): not a RIFF/WAVE file."
        case .unsupported(let name, let found):
            "\(name): needs 24000 Hz mono 16-bit PCM, found \(found). Convert with: ffmpeg -i in.wav -ar 24000 -ac 1 -c:a pcm_s16le out.wav"
        case .noAudio(let name): "\(name): the file has no audio data."
        }
    }
}

/// A 24 kHz mono PCM16 WAV file, read for streaming. Anything else is refused with the ffmpeg
/// line that fixes it.
public struct WavFile: Sendable {
    public let name: String
    public let pcm: Data

    public var seconds: Double { PCM.seconds(bytes: pcm.count) }

    public static func read(path: String) throws -> WavFile {
        let data: Data
        do { data = try Data(contentsOf: URL(fileURLWithPath: path)) } catch {
            throw WavError.unreadable(path, "\(error.localizedDescription)")
        }
        return try parse(data, name: (path as NSString).lastPathComponent)
    }

    public static func parse(_ data: Data, name: String) throws -> WavFile {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, text(bytes, 0) == "RIFF", text(bytes, 8) == "WAVE" else { throw WavError.notWave(name) }
        var format: (tag: Int, channels: Int, rate: Int, bits: Int)?
        var offset = 12
        while offset + 8 <= bytes.count {
            let id = text(bytes, offset)
            let declared = le32(bytes, offset + 4)
            let body = offset + 8
            let size = min(declared, bytes.count - body)
            if id == "fmt ", size >= 16 {
                format = (le16(bytes, body), le16(bytes, body + 2), le32(bytes, body + 4), le16(bytes, body + 14))
            } else if id == "data" {
                guard let format else { throw WavError.notWave(name) }
                guard format.tag == 1, format.channels == 1, format.rate == VoiceWire.sampleRate, format.bits == 16 else {
                    let kind = format.tag == 1 ? "PCM" : "format tag \(format.tag)"
                    throw WavError.unsupported(
                        name, "\(format.rate) Hz, \(format.channels) channel(s), \(format.bits)-bit \(kind)")
                }
                let usable = size & ~1
                guard usable > 0 else { throw WavError.noAudio(name) }
                return WavFile(name: name, pcm: Data(bytes[body..<(body + usable)]))
            }
            offset = body + declared + (declared & 1)
        }
        throw WavError.noAudio(name)
    }

    private static func text(_ bytes: [UInt8], _ at: Int) -> String {
        String(decoding: bytes[at..<(at + 4)], as: UTF8.self)
    }

    private static func le16(_ bytes: [UInt8], _ at: Int) -> Int {
        Int(bytes[at]) | Int(bytes[at + 1]) << 8
    }

    private static func le32(_ bytes: [UInt8], _ at: Int) -> Int {
        le16(bytes, at) | le16(bytes, at + 2) << 16
    }

    /// A WAV container around PCM16 mono 24 kHz, for tests and the demo.
    public static func encode(_ pcm: Data) -> Data {
        func le(_ value: Int, _ width: Int) -> Data {
            Data((0..<width).map { UInt8((value >> (8 * $0)) & 0xFF) })
        }
        var out = Data("RIFF".utf8)
        out += le(36 + pcm.count, 4)
        out += Data("WAVEfmt ".utf8)
        out += le(16, 4) + le(1, 2) + le(1, 2) + le(VoiceWire.sampleRate, 4) + le(VoiceWire.sampleRate * 2, 4)
        out += le(2, 2) + le(16, 2)
        out += Data("data".utf8) + le(pcm.count, 4) + pcm
        return out
    }
}
