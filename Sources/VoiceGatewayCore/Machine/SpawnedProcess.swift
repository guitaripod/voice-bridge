import Foundation
import Synchronization

#if os(Linux)
import Glibc

/// One child process in its own process group, so cancelling it reaches everything it started.
/// Output is either merged into `lines` or collected whole.
final class SpawnedProcess: RunningCommand, Sendable {
    enum Mode: Sendable {
        case merged
        case collected
    }

    fileprivate struct Flags {
        var cancelled = false
        var timedOut = false
        var reaped = false
    }

    fileprivate final class FlagBox: Sendable {
        let state = Mutex(Flags())

        func withLock<R: Sendable>(_ body: (inout Flags) -> R) -> R { state.withLock { body(&$0) } }
    }

    let lines: AsyncStream<String>
    private let pid: pid_t
    private let flags: FlagBox
    private let completion: Task<CommandResult, Never>

    private init(pid: pid_t, lines: AsyncStream<String>, flags: FlagBox, completion: Task<CommandResult, Never>) {
        self.pid = pid
        self.lines = lines
        self.flags = flags
        self.completion = completion
    }

    static func launch(
        path: String, arguments: [String], environment: [String: String], mode: Mode
    ) -> Result<SpawnedProcess, SpawnFailure> {
        var outPipe: [Int32] = [0, 0]
        var errPipe: [Int32] = [0, 0]
        guard makePipe(&outPipe) else { return .failure(SpawnFailure(reason: "pipe failed")) }
        guard makePipe(&errPipe) else {
            close(outPipe[0])
            close(outPipe[1])
            return .failure(SpawnFailure(reason: "pipe failed"))
        }
        let merged = mode == .merged

        var actions = posix_spawn_file_actions_t()
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, merged ? outPipe[1] : errPipe[1], 2)

        var attributes = posix_spawnattr_t()
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t()
        sigemptyset(&defaults)
        sigaddset(&defaults, SIGPIPE)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setsigmask(&attributes, &mask)
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        var argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let code = posix_spawn(&pid, path, &actions, &attributes, argv, envp)
        close(outPipe[1])
        close(errPipe[1])
        guard code == 0 else {
            close(outPipe[0])
            close(errPipe[0])
            return .failure(SpawnFailure(reason: String(cString: strerror(code))))
        }
        return .success(attach(pid: pid, outFD: outPipe[0], errFD: merged ? nil : errPipe[0], merged: merged, spareFD: merged ? errPipe[0] : nil))
    }

    private static func attach(pid: pid_t, outFD: Int32, errFD: Int32?, merged: Bool, spareFD: Int32?) -> SpawnedProcess {
        if let spareFD { close(spareFD) }
        let (stream, continuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .unbounded)
        let group = DispatchGroup()
        let collectedOut = Mutex(Data())
        let collectedErr = Mutex(Data())
        let outSplitter = Mutex(LineSplitter())
        let flags = FlagBox()

        read(fd: outFD, group: group) { chunk in
            if merged {
                outSplitter.withLock { $0.feed(chunk) }.forEach { continuation.yield($0) }
            } else {
                collectedOut.withLock { if $0.count < collectLimit { $0.append(chunk) } }
            }
        } finished: {
            if merged { outSplitter.withLock { $0.finish() }.forEach { continuation.yield($0) } }
        }
        if let errFD {
            read(fd: errFD, group: group) { chunk in
                collectedErr.withLock { if $0.count < collectLimit { $0.append(chunk) } }
            } finished: {}
        }

        let completion = Task.detached { () -> CommandResult in
            let status = await withCheckedContinuation { (waiting: CheckedContinuation<Int32, Never>) in
                DispatchQueue.global().async { waiting.resume(returning: reap(pid)) }
            }
            flags.withLock { $0.reaped = true }
            killpg(pid, SIGKILL)
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                group.notify(queue: .global()) { done.resume() }
            }
            continuation.finish()
            return CommandResult(
                status: status,
                output: String(decoding: collectedOut.withLock { $0 }, as: UTF8.self),
                error: String(decoding: collectedErr.withLock { $0 }, as: UTF8.self))
        }
        return SpawnedProcess(pid: pid, lines: stream, flags: flags, completion: completion)
    }

    private static func makePipe(_ fds: inout [Int32]) -> Bool {
        guard pipe(&fds) == 0 else { return false }
        for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        return true
    }

    private static let collectLimit = 1 << 20

    private static func read(
        fd: Int32, group: DispatchGroup, chunk: @escaping @Sendable (Data) -> Void, finished: @escaping @Sendable () -> Void
    ) {
        group.enter()
        DispatchQueue.global().async {
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = Glibc.read(fd, &buffer, buffer.count)
                if count > 0 {
                    chunk(Data(buffer[0..<count]))
                } else if count < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            close(fd)
            finished()
            group.leave()
        }
    }

    private static func reap(_ pid: pid_t) -> Int32 {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            if errno != EINTR { return 255 }
        }
        if status & 0x7F == 0 { return (status >> 8) & 0xFF }
        return 128 + (status & 0x7F)
    }

    func markTimedOut() {
        flags.withLock { $0.timedOut = true }
    }

    func cancel() {
        let first = flags.withLock { flags -> Bool in
            defer { flags.cancelled = true }
            return !flags.cancelled && !flags.reaped
        }
        guard first else { return }
        killpg(pid, SIGTERM)
        let pid = self.pid
        let flags = self.flags
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if !flags.withLock({ $0.reaped }) { killpg(pid, SIGKILL) }
        }
    }

    func wait() async -> CommandResult {
        var result = await completion.value
        result.timedOut = flags.withLock { $0.timedOut }
        return result
    }
}
#endif

struct SpawnFailure: Error, Sendable {
    var reason: String
}
