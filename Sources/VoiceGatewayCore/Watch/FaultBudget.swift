/// One recycle per fault. A second fault soon after the first means recycling does not help.
struct FaultBudget: Sendable {
    let windowSeconds: Double
    private var lastFault: Double?

    init(limits: GatewayLimits) {
        windowSeconds = limits.faultWindowSeconds
    }

    mutating func canRecycle(at now: Double) -> Bool {
        defer { lastFault = now }
        guard let lastFault else { return true }
        return now - lastFault >= windowSeconds
    }
}
