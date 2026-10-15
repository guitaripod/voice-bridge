import Testing
@testable import VoiceGatewayCore

struct BindPlanTests {
    @Test func tailnetAddressIsAddedToLoopback() {
        let plan = BindPlan.make(tailscaleOutput: "100.101.102.103\n")
        #expect(plan.hosts == ["127.0.0.1", "100.101.102.103"])
    }

    @Test func absentTailscaleBindsLoopbackOnly() {
        let plan = BindPlan.make(tailscaleOutput: nil)
        #expect(plan.hosts == ["127.0.0.1"])
        #expect(plan.notes.contains { $0.contains("loopback only") })
    }

    @Test(arguments: ["", "\n", "fd7a:115c:a1e0::1", "0.0.0.0", "192.168.1.5", "100.63.0.1", "100.128.0.1", "100.1.2", "100.1.2.3.4", "100.64.0.256", "abc", "::"])
    func anythingElseBindsLoopbackOnly(output: String) {
        #expect(BindPlan.make(tailscaleOutput: output).hosts == ["127.0.0.1"])
    }

    @Test func firstLineWins() {
        #expect(BindPlan.make(tailscaleOutput: "100.64.0.9\n100.64.0.10\n").hosts == ["127.0.0.1", "100.64.0.9"])
    }

    @Test(arguments: ["100.64.0.1", "100.127.255.254", "100.100.100.100", "", "0.0.0.0", "junk", "fd7a::1"])
    func noPlanEverBindsAWildcard(output: String) {
        let plan = BindPlan.make(tailscaleOutput: output)
        #expect(!plan.hosts.contains("0.0.0.0"))
        #expect(!plan.hosts.contains("::"))
        #expect(plan.hosts.first == "127.0.0.1")
    }
}
