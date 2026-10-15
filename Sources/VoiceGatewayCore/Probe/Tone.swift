import Foundation
import VoiceKit

/// A sine tone as PCM16, for the demo NIM and for tests that need something loud to stream.
public enum Tone {
    public static func pcm(seconds: Double, frequency: Double = 440, amplitude: Double = 6_000) -> Data {
        let count = Int(seconds * Double(VoiceWire.sampleRate))
        var out = Data(capacity: count * 2)
        for index in 0..<count {
            let value = Int16(amplitude * sin(2 * Double.pi * frequency * Double(index) / Double(VoiceWire.sampleRate)))
            out.append(UInt8(truncatingIfNeeded: value))
            out.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        return out
    }

    public static func rms(_ pcm: Data) -> Double {
        let bytes = [UInt8](pcm)
        let count = bytes.count / 2
        guard count > 0 else { return 0 }
        var sum = 0.0
        for index in 0..<count {
            let sample = Double(Int16(bitPattern: UInt16(bytes[2 * index]) | UInt16(bytes[2 * index + 1]) << 8))
            sum += sample * sample
        }
        return (sum / Double(count)).squareRoot()
    }
}
