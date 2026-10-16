import Foundation

/// The NGC CLI release the gateway installs when the machine has none. The SHA-256 values are the ones
/// NVIDIA publishes on https://ngc.nvidia.com/setup/installers/cli for this exact version; a zip that
/// does not match is refused. To move to a newer release, follow "Pinning the NGC checksum" in the README
/// and change `version` and both digests together.
enum NGCRelease {
    static let version = "4.34.10"
    static let linuxSHA256 = "58bc4d7b6901551a095ce5a43a0065b1c22d5eaf1a164d40029ee3fda11ccd47"
    static let arm64SHA256 = "5c18c5d14ad9e4b8c8ac0b5c596cd4ed33c1e4a3f2bd93f851eb974a6f3f6847"

    struct Package: Sendable, Equatable {
        var file: String
        var sha256: String

        var url: String {
            "https://api.ngc.nvidia.com/v2/resources/nvidia/ngc-apps/ngc_cli/versions/\(NGCRelease.version)/files/\(file)"
        }
    }

    static func package(machine: String) -> Package? {
        switch machine.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "x86_64", "amd64": Package(file: "ngccli_linux.zip", sha256: linuxSHA256)
        case "aarch64", "arm64": Package(file: "ngccli_arm64.zip", sha256: arm64SHA256)
        default: nil
        }
    }
}
