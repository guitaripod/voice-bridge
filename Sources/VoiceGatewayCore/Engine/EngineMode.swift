import Foundation

/// Who runs the voice container. `managed`: this gateway starts it when a call needs it and stops it
/// when idle. `external`: someone else does (the optional systemd unit), and the gateway only talks to it.
/// `auto` decides once at start: managed unless something already answers on the NIM port.
public enum EngineMode: String, Sendable, Equatable {
    case auto
    case managed
    case external

    /// The gateway can only manage the container that publishes `127.0.0.1:9000`, so any other NIM address
    /// is somebody else's engine.
    public static func effective(_ configured: EngineMode, nimURL: String) -> EngineMode {
        guard configured != .external else { return .external }
        guard let parts = URLComponents(string: nimURL), let host = parts.host else { return .external }
        let local = ["127.0.0.1", "localhost", "::1"].contains(host)
        return local && (parts.port ?? 80) == VoiceRequirements.nimPort ? configured : .external
    }
}
