import SetupKit

/// The one copyable command for what only a person with administrator rights can do.
enum FixCommands {
    static let dockerReason =
        "Installing system packages, starting the Docker service and joining the docker group need administrator rights."
    static let cdiReason = "Describing the GPU to containers writes into /etc/cdi, which needs administrator rights."
    static let cdiCommand = "sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml"

    static let archDocker =
        "sudo pacman -S --needed docker nvidia-container-toolkit && sudo systemctl enable --now docker && sudo usermod -aG docker $USER"

    static let debianDocker = [
        "sudo apt-get update && sudo apt-get install -y docker.io curl gnupg",
        "curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg",
        "curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list",
        "sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit",
        "sudo systemctl enable --now docker && sudo usermod -aG docker $USER",
    ].joined(separator: " && ")

    static let otherDocker =
        "echo 'Install Docker (https://docs.docker.com/engine/install/) and the NVIDIA Container Toolkit (https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html), start Docker and add yourself to the docker group'"

    static func docker(family: OSFamily) -> SetupFix {
        let command =
            switch family {
            case .arch: archDocker
            case .debian: debianDocker
            case .other: otherDocker
            }
        return SetupFix(id: VoiceRequirements.installDockerFix, kind: .command, command: command, reason: dockerReason)
    }

    static var cdi: SetupFix {
        SetupFix(id: VoiceRequirements.generateCDIFix, kind: .command, command: cdiCommand, reason: cdiReason)
    }
}
