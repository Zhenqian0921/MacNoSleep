import Foundation
import IOKit.pwr_mgt

public struct AppError: Error, CustomStringConvertible, Sendable {
    public let description: String

    public init(description: String) {
        self.description = description
    }
}

public struct CommandResult: Sendable {
    public let status: Int32
    public let output: String
    public let error: String

    public init(status: Int32, output: String, error: String) {
        self.status = status
        self.output = output
        self.error = error
    }
}

@discardableResult
public func runCommand(_ executable: String, _ arguments: [String], inheritIO: Bool = false) throws -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    var outputPipe: Pipe?
    var errorPipe: Pipe?

    if inheritIO {
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
    } else {
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        outputPipe = out
        errorPipe = err
    }

    try process.run()
    process.waitUntilExit()

    let output = outputPipe.map { pipe in
        String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    } ?? ""
    let error = errorPipe.map { pipe in
        String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    } ?? ""

    return CommandResult(status: process.terminationStatus, output: output, error: error)
}

public final class PowerAssertions {
    public enum Kind: Hashable {
        case systemIdle
        case displayIdle
    }

    private var ids: [Kind: IOPMAssertionID] = [:]

    public init() {}

    public var hasSystemIdle: Bool {
        ids[.systemIdle] != nil
    }

    public var hasDisplayIdle: Bool {
        ids[.displayIdle] != nil
    }

    public func acquireSystemIdle(reason: String) throws {
        try acquire(.systemIdle, type: kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, reason: reason)
    }

    public func acquireDisplayIdle(reason: String) throws {
        try acquire(.displayIdle, type: kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, reason: reason)
    }

    public func releaseSystemIdle() {
        release(.systemIdle)
    }

    public func releaseDisplayIdle() {
        release(.displayIdle)
    }

    public func releaseAll() {
        for kind in Array(ids.keys) {
            release(kind)
        }
    }

    deinit {
        releaseAll()
    }

    private func acquire(_ kind: Kind, type: CFString, reason: String) throws {
        if ids[kind] != nil {
            return
        }

        var assertionID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            type,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID
        )

        guard result == kIOReturnSuccess else {
            throw AppError(description: "IOPMAssertionCreateWithName failed: \(String(format: "0x%08x", result))")
        }

        ids[kind] = assertionID
    }

    private func release(_ kind: Kind) {
        guard let id = ids.removeValue(forKey: kind) else {
            return
        }

        IOPMAssertionRelease(id)
    }
}

public struct SleepDisabledStatus: Sendable {
    public let rawValue: String?

    public init(rawValue: String?) {
        self.rawValue = rawValue
    }

    public var isDisabled: Bool? {
        switch rawValue {
        case "1":
            true
        case "0":
            false
        case nil:
            nil
        default:
            nil
        }
    }

    public var displayText: String {
        switch rawValue {
        case "1":
            "pmset sleep disabled: 1 (system sleep disabled)"
        case "0":
            "pmset sleep disabled: 0 (normal sleep allowed)"
        case let value?:
            "pmset sleep disabled: \(value)"
        case nil:
            "pmset sleep disabled: not reported on this Mac/macOS version"
        }
    }
}

public enum PowerControl {
    private static let timerDirectory = "/private/tmp/mac-nosleep"
    private static let lidTimerTokenPath = "/private/tmp/mac-nosleep/lid-token"

    public static func setDisableSleepUsingSudo(_ enabled: Bool) throws {
        let value = enabled ? "1" : "0"
        let shellCommand = "/bin/rm -f \(shellQuoted(lidTimerTokenPath)); /usr/bin/pmset -a disablesleep \(value)"
        let result = try runCommand("/usr/bin/sudo", ["/bin/sh", "-c", shellCommand], inheritIO: true)

        guard result.status == 0 else {
            throw AppError(description: "pmset failed with exit code \(result.status)")
        }
    }

    public static func setDisableSleepUsingAuthorizationDialog(_ enabled: Bool) throws {
        let value = enabled ? "1" : "0"
        let shellCommand = "/bin/rm -f \(shellQuoted(lidTimerTokenPath)); /usr/bin/pmset -a disablesleep \(value)"
        try runAdminShell(shellCommand)
    }

    @discardableResult
    public static func setDisableSleepUsingAuthorizationDialog(durationSeconds: Int) throws -> String {
        guard durationSeconds > 0 else {
            throw AppError(description: "durationSeconds must be greater than zero")
        }

        let token = UUID().uuidString
        let tokenPath = shellQuoted(lidTimerTokenPath)
        let tokenValue = shellQuoted(token)
        let directory = shellQuoted(timerDirectory)

        let shellCommand = """
        /bin/mkdir -p \(directory) && /bin/echo \(tokenValue) > \(tokenPath) && /usr/bin/pmset -a disablesleep 1 && { (/bin/sleep \(durationSeconds); if [ "$(/bin/cat \(tokenPath) 2>/dev/null)" = \(tokenValue) ]; then /usr/bin/pmset -a disablesleep 0; /bin/rm -f \(tokenPath); fi) >/dev/null 2>&1 & }
        """

        try runAdminShell(shellCommand)
        return token
    }

    public static func readSleepDisabledStatus() throws -> SleepDisabledStatus {
        let result = try runCommand("/usr/bin/pmset", ["-g"])

        guard result.status == 0 else {
            throw AppError(description: "pmset -g failed: \(result.error.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        let disablesleep = parsePMSetValue(named: "disablesleep", from: result.output)
        let sleepDisabled = parsePMSetValue(named: "SleepDisabled", from: result.output)
        return SleepDisabledStatus(rawValue: disablesleep ?? sleepDisabled)
    }

    public static func sleepPreventionAssertionLines() throws -> [String] {
        let result = try runCommand("/usr/bin/pmset", ["-g", "assertions"])

        guard result.status == 0 else {
            throw AppError(description: "pmset -g assertions failed: \(result.error.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        return result.output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { line in
                line.contains("PreventUserIdleSystemSleep")
                    || line.contains("PreventUserIdleDisplaySleep")
                    || line.contains("PreventSystemSleep")
                    || line.contains("NoIdleSleepAssertion")
                    || line.contains("MacNoSleep")
            }
    }

    private static func parsePMSetValue(named key: String, from output: String) -> String? {
        for line in output.split(separator: "\n") {
            let parts = line.split { character in
                character == " " || character == "\t"
            }

            if let first = parts.first, String(first) == key {
                return parts.dropFirst().last.map(String.init)
            }
        }

        return nil
    }

    private static func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func runAdminShell(_ shellCommand: String) throws {
        let script = "do shell script \"\(appleScriptEscaped(shellCommand))\" with administrator privileges"
        let result = try runCommand("/usr/bin/osascript", ["-e", script])

        guard result.status == 0 else {
            let detail = (result.error.isEmpty ? result.output : result.error)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw AppError(description: detail.isEmpty ? "administrator authorization failed" : detail)
        }
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
