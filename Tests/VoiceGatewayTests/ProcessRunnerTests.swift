import Foundation
import Testing
@testable import VoiceGatewayCore

struct ProcessRunnerTests {
    @Test func runKeepsStdoutStderrAndStatusApart() async {
        let bin = FakeBin()
        bin.install("tool", "echo out; echo err >&2; exit 3")
        let result = await bin.runner().run(CommandSpec("tool"))
        #expect(result.launched)
        #expect(result.status == 3)
        #expect(result.output == "out\n")
        #expect(result.error == "err\n")
        #expect(!result.succeeded)
    }

    @Test func aProgramThatIsNotThereIsNotLaunched() async {
        let result = await FakeBin().runner().run(CommandSpec("nothing-like-this"))
        #expect(!result.launched)
        #expect(result.status == 127)
        #expect(!result.succeeded)
    }

    @Test func argumentsAndEnvironmentArrive() async {
        let bin = FakeBin()
        bin.install("tool", "echo \"$1|$2|$SOME_VAR|$INHERITED\"")
        let runner = bin.runner(extra: ["INHERITED": "base"])
        let result = await runner.run(CommandSpec("tool", ["a b", "c"], environment: ["SOME_VAR": "yes"]))
        #expect(result.output == "a b|c|yes|base\n")
    }

    @Test func aSlowProgramIsKilledAtItsTimeout() async {
        let bin = FakeBin()
        bin.install("slow", "sleep 30")
        let started = ContinuousClock.now
        let result = await bin.runner().run(CommandSpec("slow", timeout: 0.3))
        #expect(result.timedOut)
        #expect(!result.succeeded)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func streamedLinesEndOnCarriageReturnsToo() async {
        let bin = FakeBin()
        bin.install("pull", "printf 'one\\ntwo 10%%\\rtwo 50%%\\rtwo 100%%\\n'; echo oops >&2; exit 2")
        let command = bin.runner().stream(CommandSpec("pull"))
        var lines: [String] = []
        for await line in command.lines { lines.append(line) }
        let result = await command.wait()
        #expect(Set(lines) == ["one", "two 10%", "two 50%", "two 100%", "oops"])
        #expect(lines.prefix(4).elementsEqual(["one", "two 10%", "two 50%", "two 100%"]))
        #expect(result.status == 2)
    }

    @Test func aStreamOfAMissingProgramEndsAtOnce() async {
        let command = FakeBin().runner().stream(CommandSpec("nope"))
        var count = 0
        for await _ in command.lines { count += 1 }
        #expect(count == 0)
        #expect(await command.wait().launched == false)
    }

    @Test func cancelReachesTheWholeProcessGroup() async throws {
        let bin = FakeBin()
        let pidFile = bin.url.appendingPathComponent("child.pid")
        bin.install("parent", "sleep 60 &\necho $! > '\(pidFile.path)'\necho started\nwait")
        let command = bin.runner().stream(CommandSpec("parent"))
        var iterator = command.lines.makeAsyncIterator()
        #expect(await iterator.next() == "started")
        let child = try #require(Int32(String(contentsOfFile: pidFile.path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(child, 0) == 0)
        command.cancel()
        let result = await command.wait()
        #expect(result.status != 0)
        #expect(await eventually { kill(child, 0) != 0 })
    }

    @Test func cancellingTheCallerKillsARun() async {
        let bin = FakeBin()
        bin.install("slow", "sleep 30")
        let runner = bin.runner()
        let task = Task { await runner.run(CommandSpec("slow")) }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let result = await task.value
        #expect(!result.succeeded)
    }
}
