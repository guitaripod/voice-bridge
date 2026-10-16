import Foundation
import Testing
@testable import VoiceGatewayCore

struct MachineParsingTests {
    @Test func gpuLineIsNameAndTwoNumbers() {
        let gpu = NvidiaSMI.parseGPU("NVIDIA RTX PRO 6000 Blackwell Workstation Edition, 97887, 58562\n")
        #expect(gpu?.name == "NVIDIA RTX PRO 6000 Blackwell Workstation Edition")
        #expect(gpu?.totalMB == 97_887)
        #expect(gpu?.usedMB == 58_562)
        #expect(gpu?.freeMB == 39_325)
    }

    @Test func aNameWithACommaKeepsItsNumbers() {
        let gpu = NvidiaSMI.parseGPU("Fancy, Card X, 81920, 10")
        #expect(gpu?.name == "Fancy, Card X")
        #expect(gpu?.totalMB == 81_920)
    }

    @Test func unreadableMemoryIsKnownAsUnknown() {
        let gpu = NvidiaSMI.parseGPU("NVIDIA GB10, [N/A], [N/A]")
        #expect(gpu?.name == "NVIDIA GB10")
        #expect(gpu?.totalMB == nil)
        #expect(gpu?.freeMB == nil)
    }

    @Test func noOutputIsNoGPU() {
        #expect(NvidiaSMI.parseGPU("") == nil)
        #expect(NvidiaSMI.parseGPU("\n  \n") == nil)
    }

    @Test func holdersKeepTheirProgramNameWhateverTheCommandLineHolds() {
        let output = """
            1845, /usr/bin/kwin_wayland, 367
            3706, /opt/1Password/1password --type=gpu-process --ozone-platform=wayland --flag=a,b,c, 38
            3827043, .venv/bin/python, 18156
            3843796, /home/marcus/llama.cpp/build/bin/llama-server, 5350
            3856376, /home/marcus/llama.cpp/build/bin/llama-server, 30566
            not a line
            """
        let holders = NvidiaSMI.parseHolders(output)
        #expect(holders.count == 5)
        #expect(holders[1].name == "1password")
        #expect(holders[1].usedMB == 38)
        #expect(holders[2].name == "python")
        var gpu = GPUFacts(name: "x", totalMB: 97_887, usedMB: 58_562)
        gpu.holders = holders
        #expect(gpu.holderNames == ["llama-server", "python"])
    }

    @Test func whenNothingIsHeavyTheLargestAreNamed() {
        var gpu = GPUFacts(name: "x")
        gpu.holders = [GPUHolder(pid: 1, name: "a", usedMB: 10), GPUHolder(pid: 2, name: "b", usedMB: 300), GPUHolder(pid: 3, name: "c", usedMB: 5), GPUHolder(pid: 4, name: "d", usedMB: 1)]
        #expect(gpu.holderNames == ["b", "a", "c"])
    }

    @Test func osFamiliesFollowIdAndIdLike() {
        #expect(OSRelease.parse("ID=arch\n").family == .arch)
        #expect(OSRelease.parse("ID=endeavouros\nID_LIKE=arch\n").family == .arch)
        #expect(OSRelease.parse("ID=ubuntu\nID_LIKE=debian\n").family == .debian)
        #expect(OSRelease.parse("ID=\"debian\"\n").family == .debian)
        #expect(OSRelease.parse("ID=pop\nID_LIKE=\"ubuntu debian\"\n").family == .debian)
        #expect(OSRelease.parse("ID=fedora\n").family == .other)
        #expect(OSRelease.parse("").id == "unknown")
    }

    @Test func dockerFailuresSayWhichWayItIsUnusable() {
        #expect(DockerState.interpret(.notLaunched("x")) == .missing)
        #expect(DockerState.interpret(CommandResult(output: "29.8.2")) == .ready)
        #expect(DockerState.interpret(CommandResult(status: 1, error: "permission denied while trying to connect")) == .denied)
        #expect(DockerState.interpret(CommandResult(status: 1, error: "Cannot connect to the Docker daemon")) == .stopped)
    }

    @Test func onlyAnExactNameIsOurContainer() {
        let name = VoiceRequirements.containerName
        #expect(DockerPS.state(of: name, in: "") == .absent)
        #expect(DockerPS.state(of: name, in: "\(name)-old|running|Up 2 hours\n") == .absent)
        #expect(DockerPS.state(of: name, in: "x|running|Up\n\(name)|running|Up 3 minutes\n") == .running)
        #expect(DockerPS.state(of: name, in: "\(name)|exited|Exited (1)\n") == .other("exited"))
    }

    @Test func dfReportsAvailableMegabytes() {
        let out = "Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/nvme0n1p2 976000000 100 204800000 12% /home\n"
        #expect(DiskSpace.parse(out) == 200_000)
        #expect(DiskSpace.parse("garbage") == nil)
    }

    @Test func linesSplitOnCarriageReturnsAndDropEscapes() {
        var splitter = LineSplitter()
        #expect(splitter.feed(Data("abc: Pulling fs".utf8)) == [])
        #expect(splitter.feed(Data(" layer\n\u{1B}[2K12%\r24%\r\nlast".utf8)) == ["abc: Pulling fs layer", "12%", "24%"])
        #expect(splitter.finish() == ["last"])
        #expect(splitter.finish() == [])
    }
}
