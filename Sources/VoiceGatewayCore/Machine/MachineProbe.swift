import Foundation

/// Reads the machine. Each fact is one command through the runner (or one file), so a fake runner and
/// a temporary directory make any machine.
struct MachineProbe: Sendable {
    static let commandTimeout = 15.0

    let runner: any CommandRunner
    let paths: MachinePaths
    let nim: any NIMHealthProbe

    func facts() async -> MachineFacts {
        async let gpu = self.gpu()
        async let docker = self.dockerFacts()
        async let cdi = self.cdiFacts()
        async let model = self.model()
        async let health = nim.check()
        let (docks, devices) = await (docker, cdi)
        return MachineFacts(
            gpu: await gpu, os: osRelease(), docker: docks.state, toolkitInstalled: devices.toolkit, cdi: devices.present,
            imageBytes: docks.imageBytes, model: await model, container: docks.container, nim: await health)
    }

    func gpu() async -> GPUFacts? {
        let query = await runner.run(CommandSpec("nvidia-smi", NvidiaSMI.gpuQuery, timeout: Self.commandTimeout))
        guard query.succeeded, var facts = NvidiaSMI.parseGPU(query.output) else { return nil }
        let apps = await runner.run(CommandSpec("nvidia-smi", NvidiaSMI.holderQuery, timeout: Self.commandTimeout))
        if apps.succeeded { facts.holders = NvidiaSMI.parseHolders(apps.output) }
        return facts
    }

    func osRelease() -> OSRelease {
        guard let text = try? String(contentsOf: paths.osRelease, encoding: .utf8) else { return .unknown }
        return OSRelease.parse(text)
    }

    func model() async -> ModelStatus {
        let directory = paths.modelDir
        return await Task.detached { ModelDirectory.inspect(directory) }.value
    }

    struct DockerFindings: Sendable {
        var state: DockerState
        var imageBytes: Int64?
        var container: ContainerState
    }

    func dockerFacts() async -> DockerFindings {
        let version = await runner.run(
            CommandSpec("docker", ["version", "--format", "{{.Server.Version}}"], timeout: Self.commandTimeout))
        let state = DockerState.interpret(version)
        guard state == .ready else { return DockerFindings(state: state, imageBytes: nil, container: .absent) }
        async let image = imageBytes()
        async let container = containerState()
        return DockerFindings(state: state, imageBytes: await image, container: await container)
    }

    func imageBytes() async -> Int64? {
        let result = await runner.run(
            CommandSpec("docker", ["image", "inspect", VoiceRequirements.imageName, "--format", "{{.Size}}"], timeout: Self.commandTimeout))
        guard result.succeeded else { return nil }
        return Int64(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    func containerState() async -> ContainerState {
        let result = await runner.run(
            CommandSpec(
                "docker",
                ["ps", "-a", "--filter", "name=\(VoiceRequirements.containerName)", "--format", DockerPS.format],
                timeout: Self.commandTimeout))
        guard result.succeeded else { return .absent }
        return DockerPS.state(of: VoiceRequirements.containerName, in: result.output)
    }

    struct CDIFindings: Sendable {
        var toolkit: Bool
        var present: Bool
    }

    func cdiFacts() async -> CDIFindings {
        let listed = await runner.run(CommandSpec("nvidia-ctk", ["cdi", "list"], timeout: Self.commandTimeout))
        let toolkit = listed.launched
        if listed.succeeded, listed.output.contains("nvidia.com/gpu=") || listed.error.contains("nvidia.com/gpu=") {
            return CDIFindings(toolkit: toolkit, present: true)
        }
        return CDIFindings(toolkit: toolkit, present: specFileExists())
    }

    private func specFileExists() -> Bool {
        paths.cdiDirectories.contains { directory in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            return names.contains { $0.lowercased().contains("nvidia") && ($0.hasSuffix(".yaml") || $0.hasSuffix(".json")) }
        }
    }
}
