import Darwin
import Dispatch
import Foundation
import MacNoSleepCore

final class SignalWaiter {
    private let semaphore = DispatchSemaphore(value: 0)
    private var sources: [DispatchSourceSignal] = []

    init(signals: [Int32] = [SIGINT, SIGTERM]) {
        let queue = DispatchQueue(label: "MacNoSleep.signals")

        for signalNumber in signals {
            Darwin.signal(signalNumber, SIG_IGN)

            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
            source.setEventHandler { [semaphore] in
                semaphore.signal()
            }
            source.resume()
            sources.append(source)
        }
    }

    func wait() {
        semaphore.wait()
    }
}

@main
struct MacNoSleep {
    static func main() {
        do {
            try run(Array(CommandLine.arguments.dropFirst()))
        } catch let error as AppError {
            fputs("error: \(error.description)\n", stderr)
            exit(1)
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func run(_ arguments: [String]) throws {
        guard let command = arguments.first else {
            printUsage()
            return
        }

        let rest = Array(arguments.dropFirst())

        switch command {
        case "-h", "--help", "help":
            printUsage()
        case "hold":
            try hold(rest)
        case "lid":
            try lid(rest)
        case "status":
            try printStatus()
        default:
            throw AppError(description: "unknown command '\(command)'\n\n\(usageText)")
        }
    }

    private static func hold(_ arguments: [String]) throws {
        var keepDisplayAwake = false
        var reason = "MacNoSleep hold"

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]

            switch argument {
            case "--display":
                keepDisplayAwake = true
            case "--reason":
                guard index + 1 < arguments.count else {
                    throw AppError(description: "--reason requires text")
                }
                reason = arguments[index + 1]
                index += 1
            case "-h", "--help":
                print(holdUsageText)
                return
            default:
                throw AppError(description: "unknown hold option '\(argument)'\n\n\(holdUsageText)")
            }

            index += 1
        }

        let assertions = PowerAssertions()
        try assertions.acquireSystemIdle(reason: reason)

        if keepDisplayAwake {
            try assertions.acquireDisplayIdle(reason: reason)
        }

        print("Sleep hold is active.")
        print("This prevents idle sleep while macOS remains awake.")
        print("It does not reliably override lid-close sleep; use 'mac-nosleep lid on --force' for that pmset switch.")
        print("Press Ctrl-C to release.")

        SignalWaiter().wait()
        assertions.releaseAll()
        print("\nSleep hold released.")
    }

    private static func lid(_ arguments: [String]) throws {
        guard let action = arguments.first else {
            print(lidUsageText)
            return
        }

        let options = Array(arguments.dropFirst())

        switch action {
        case "-h", "--help", "help":
            print(lidUsageText)
        case "status":
            try requireNoOptions(options, for: "lid status")
            try printLidStatus()
        case "on":
            try requireOnly(options, allowed: ["--force"], for: "lid on")
            guard options.contains("--force") else {
                throw AppError(description: """
                Refusing to enable close-lid no-sleep without --force.
                Closing a running Mac can trap heat. If you accept that risk, run:
                  mac-nosleep lid on --force

                Restore normal sleep behavior with:
                  mac-nosleep lid off
                """)
            }
            try setDisableSleep(true)
            try printLidStatus()
        case "off":
            try requireNoOptions(options, for: "lid off")
            try setDisableSleep(false)
            try printLidStatus()
        default:
            throw AppError(description: "unknown lid action '\(action)'\n\n\(lidUsageText)")
        }
    }

    private static func setDisableSleep(_ enabled: Bool) throws {
        let value = enabled ? "1" : "0"
        print("Running: sudo pmset -a disablesleep \(value)")
        try PowerControl.setDisableSleepUsingSudo(enabled)
    }

    private static func printStatus() throws {
        try printLidStatus()
        print("")
        try printAssertionStatus()
    }

    private static func printLidStatus() throws {
        print(try PowerControl.readSleepDisabledStatus().displayText)
    }

    private static func printAssertionStatus() throws {
        let interestingLines = try PowerControl.sleepPreventionAssertionLines()

        if interestingLines.isEmpty {
            print("Active sleep-prevention assertions: none found in pmset summary")
        } else {
            print("Active sleep-prevention assertions:")
            for line in interestingLines {
                print(line)
            }
        }
    }

    private static func requireNoOptions(_ options: [String], for command: String) throws {
        guard options.isEmpty else {
            throw AppError(description: "\(command) does not accept option '\(options[0])'")
        }
    }

    private static func requireOnly(_ options: [String], allowed: Set<String>, for command: String) throws {
        for option in options where !allowed.contains(option) {
            throw AppError(description: "\(command) does not accept option '\(option)'")
        }
    }

    private static func printUsage() {
        print(usageText)
    }

    private static let usageText = """
    MacNoSleep controls macOS sleep prevention.

    Usage:
      mac-nosleep hold [--display] [--reason TEXT]
      mac-nosleep lid status
      mac-nosleep lid on --force
      mac-nosleep lid off
      mac-nosleep status

    Notes:
      hold uses IOKit assertions. It prevents idle sleep, but does not reliably override lid-close sleep.
      lid on calls: sudo pmset -a disablesleep 1
      lid off calls: sudo pmset -a disablesleep 0
      Close-lid no-sleep can trap heat; use power, ventilation, and restore normal sleep when done.
    """

    private static let holdUsageText = """
    Usage:
      mac-nosleep hold [--display] [--reason TEXT]

    Options:
      --display       Also keep the display awake.
      --reason TEXT   Assertion name shown by pmset.
    """

    private static let lidUsageText = """
    Usage:
      mac-nosleep lid status
      mac-nosleep lid on --force
      mac-nosleep lid off

    Commands:
      status   Show the current pmset disablesleep value.
      on       Disable system sleep through pmset. Requires sudo and --force.
      off      Restore normal sleep through pmset. Requires sudo.
    """
}
