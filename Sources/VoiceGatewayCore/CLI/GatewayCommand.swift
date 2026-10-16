import Foundation

/// What `voice-bridge` was asked to do. No argument serves; every other word is a command of its own,
/// and a word it does not know is refused rather than ignored, so a typo never starts a second server.
public enum GatewayCommand: Equatable, Sendable {
    public struct DoctorOptions: Equatable, Sendable {
        public var json = false
        public var commands = false

        public init(json: Bool = false, commands: Bool = false) {
            self.json = json
            self.commands = commands
        }
    }

    case serve
    case version
    case help
    case doctor(DoctorOptions)
    case update
    case refused(String)

    public static let usage = """
        usage:
          voice-bridge                    serve (what the service runs)
          voice-bridge --version          print the version
          voice-bridge doctor [--json]    check this machine for voice calls; exit 3 when it cannot run them
          voice-bridge doctor --commands  print only the commands that need administrator rights
          voice-bridge update             install the newest release and restart when no call or download is running
        """

    public static func parse(_ arguments: [String]) -> GatewayCommand {
        guard let first = arguments.first else { return .serve }
        let rest = Array(arguments.dropFirst())
        switch first {
        case "--version", "version":
            return rest.isEmpty ? .version : .refused("\(first) takes no arguments")
        case "--help", "-h", "help":
            return .help
        case "doctor":
            return parseDoctor(rest)
        case "update":
            return rest.isEmpty ? .update : .refused("update takes no arguments, got \(rest[0])")
        default:
            return .refused("unknown command \"\(first)\"")
        }
    }

    private static func parseDoctor(_ arguments: [String]) -> GatewayCommand {
        var options = DoctorOptions()
        for argument in arguments {
            switch argument {
            case "--json": options.json = true
            case "--commands": options.commands = true
            default: return .refused("doctor does not know \"\(argument)\"")
            }
        }
        if options.json && options.commands { return .refused("doctor takes --json or --commands, not both") }
        return .doctor(options)
    }
}
