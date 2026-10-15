import Foundation
import Testing
import VoiceKit
@testable import VoiceGatewayCore

struct WatchTests {
    let limits = GatewayLimits.contract

    @Test func loopNeedsTheSameFourWordsThreeTimes() {
        var loop = LoopDetector(limits: limits)
        let hit1 = loop.feed("I will look into it. ")
        #expect(!hit1)
        let hit2 = loop.feed("I will look into it. ")
        #expect(!hit2)
        let hit3 = loop.feed("I will look into it. ")
        #expect(hit3)
    }

    @Test func ordinarySpeechIsNoLoop() {
        var loop = LoopDetector(limits: limits)
        let hit4 = loop.feed("Sent. I passed your request to the agent, and it has started working on the failing test.")
        #expect(!hit4)
    }

    @Test func loopLooksOnlyAtTheTail() {
        var loop = LoopDetector(limits: limits)
        _ = loop.feed("go on now please. go on now please. ")
        let filler = "then the build tool finished compiling every module without a single warning and the test runner started its first suite of checks while the linter looked at formatting. "
        _ = loop.feed(filler)
        let late = loop.feed("go on now please.")
        #expect(!late)
    }

    @Test func cumulativeDeltasAreNotDoubled() {
        var text = TextAccumulator()
        text.append("fix")
        text.append("fix the")
        text.append("fix the test")
        #expect(text.text == "fix the test")
        var incremental = TextAccumulator()
        for piece in ["fix", " the", " test"] { incremental.append(piece) }
        #expect(incremental.text == "fix the test")
    }

    @Test func runawaySpeechAfterTwentyFiveSeconds() {
        var watch = RunawayWatch(limits: limits)
        let hit7 = watch.audio(seconds: 20, at: 0)
        #expect(!hit7)
        let hit8 = watch.audio(seconds: 5, at: 1)
        #expect(!hit8)
        let hit9 = watch.audio(seconds: 0.08, at: 2)
        #expect(hit9)
    }

    @Test func personSpeakingResetsTheSpeechClock() {
        var watch = RunawayWatch(limits: limits)
        let hit10 = watch.audio(seconds: 24, at: 0)
        #expect(!hit10)
        watch.userSpoke()
        let hit11 = watch.audio(seconds: 24, at: 1)
        #expect(!hit11)
    }

    @Test func runawayTailThreeSecondsAfterDone() {
        var watch = RunawayWatch(limits: limits)
        watch.responseDone(at: 10)
        let hit12 = watch.audio(seconds: 0.08, at: 12.9)
        #expect(!hit12)
        let hit13 = watch.audio(seconds: 0.08, at: 13.1)
        #expect(hit13)
        watch.responseStarted()
        let hit14 = watch.audio(seconds: 0.08, at: 20)
        #expect(!hit14)
    }

    @Test func recycleDueAtNinetySecondsOrFourTurns() {
        var audio = RecyclePolicy(limits: limits)
        audio.addAudio(seconds: 89.9)
        #expect(!audio.due)
        audio.addAudio(seconds: 0.1)
        #expect(audio.due)
        audio.reset()
        #expect(!audio.due)
        var turns = RecyclePolicy(limits: limits)
        for _ in 0..<3 { turns.turnEnded() }
        #expect(!turns.due)
        turns.turnEnded()
        #expect(turns.due)
    }

    @Test func replayKeepsTheLastTwoSeconds() {
        var replay = ReplayBuffer(seconds: 2)
        replay.append(Data(repeating: 1, count: 60_000))
        replay.append(Data(repeating: 2, count: 60_000))
        let audio = replay.drain()
        #expect(audio.count == PCM.bytes(seconds: 2))
        #expect(audio.last == 2)
        #expect(audio.first == 1)
        let hit15 = replay.drain().isEmpty
        #expect(hit15)
    }

    @Test func secondFaultSoonAfterTheFirstGetsNoRecycle() {
        var budget = FaultBudget(limits: limits)
        let hit16 = budget.canRecycle(at: 100)
        #expect(hit16)
        let hit17 = budget.canRecycle(at: 130)
        #expect(!hit17)
        let hit18 = budget.canRecycle(at: 200)
        #expect(hit18)
    }

    @Test func dispatchJoinsAndClips() {
        var buffer = DispatchBuffer()
        buffer.append("  fix the test ")
        buffer.append("")
        buffer.append("and run it")
        let hit19 = buffer.take()
        #expect(hit19 == "fix the test and run it")
        let hit20 = buffer.take()
        #expect(hit20 == nil)
        buffer.append(String(repeating: "word ", count: 2_000))
        let clipped = buffer.take() ?? ""
        #expect(clipped.count <= VoiceWire.dispatchLimit)
        #expect(clipped.count > VoiceWire.dispatchLimit - 10)
    }

    @Test func refusedTextGoesBackInFront() {
        var buffer = DispatchBuffer()
        buffer.append("later words")
        buffer.requeue("earlier words")
        let hit21 = buffer.take()
        #expect(hit21 == "earlier words later words")
    }
}
