import AppKit
import MacNoSleepCore
import SwiftUI

@main
struct MacNoSleepMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = SleepMenuModel()

    var body: some Scene {
        MenuBarExtra {
            Button {
                model.toggleSystemHold()
            } label: {
                Label(model.systemHoldTitle, systemImage: model.systemHoldEnabled ? "checkmark.circle.fill" : "circle")
            }

            Button {
                model.toggleDisplayHold()
            } label: {
                Label(model.displayHoldTitle, systemImage: model.displayHoldEnabled ? "checkmark.circle.fill" : "display")
            }

            Divider()

            Menu {
                ForEach(LidSleepDuration.allCases) { duration in
                    Button {
                        model.selectLidDuration(duration)
                    } label: {
                        Label(duration.title, systemImage: model.selectedLidDuration == duration ? "checkmark" : "clock")
                    }
                }
            } label: {
                Label(model.durationMenuTitle, systemImage: "timer")
            }

            Button {
                model.toggleLidSleepDisabled()
            } label: {
                Label(model.lidSleepTitle, systemImage: model.lidSleepDisabled == true ? "checkmark.circle.fill" : "laptopcomputer")
            }
            .disabled(model.isChangingLidSleep)

            Button {
                model.refreshStatus()
            } label: {
                Label("刷新状态", systemImage: "arrow.clockwise")
            }

            Divider()

            Text(model.statusText)

            if let message = model.message {
                Text(message)
            }

            Divider()

            Button("退出 MacNoSleep") {
                NSApp.terminate(nil)
            }
        } label: {
            Label("MacNoSleep", systemImage: model.menuBarSymbol)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

enum LidSleepDuration: String, CaseIterable, Identifiable, Sendable {
    case fifteenMinutes
    case thirtyMinutes
    case oneHour
    case twoHours
    case fourHours
    case manual

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .fifteenMinutes:
            "15 分钟"
        case .thirtyMinutes:
            "30 分钟"
        case .oneHour:
            "1 小时"
        case .twoHours:
            "2 小时"
        case .fourHours:
            "4 小时"
        case .manual:
            "手动关闭"
        }
    }

    var seconds: Int? {
        switch self {
        case .fifteenMinutes:
            15 * 60
        case .thirtyMinutes:
            30 * 60
        case .oneHour:
            60 * 60
        case .twoHours:
            2 * 60 * 60
        case .fourHours:
            4 * 60 * 60
        case .manual:
            nil
        }
    }
}

@MainActor
final class SleepMenuModel: ObservableObject {
    @Published private(set) var systemHoldEnabled = false
    @Published private(set) var displayHoldEnabled = false
    @Published private(set) var lidSleepDisabled: Bool?
    @Published private(set) var selectedLidDuration: LidSleepDuration
    @Published private(set) var isChangingLidSleep = false
    @Published private(set) var statusText = "正在读取状态..."
    @Published private(set) var message: String?

    private static let durationDefaultsKey = "MacNoSleep.SelectedLidDuration"

    private let assertions = PowerAssertions()
    private var scheduledLidEndDate: Date?
    private var statusRefreshTask: Task<Void, Never>?

    init() {
        let rawDuration = UserDefaults.standard.string(forKey: Self.durationDefaultsKey)
        selectedLidDuration = rawDuration.flatMap(LidSleepDuration.init(rawValue:)) ?? .thirtyMinutes
        refreshStatus()
    }

    var systemHoldTitle: String {
        systemHoldEnabled ? "停止空闲不睡眠" : "开启空闲不睡眠"
    }

    var displayHoldTitle: String {
        displayHoldEnabled ? "停止屏幕常亮" : "开启屏幕常亮"
    }

    var lidSleepTitle: String {
        if isChangingLidSleep {
            return "正在修改合盖设置..."
        }

        return lidSleepDisabled == true ? "恢复合盖睡眠" : "开启合盖不睡眠（\(selectedLidDuration.title)）"
    }

    var durationMenuTitle: String {
        "合盖时长：\(selectedLidDuration.title)"
    }

    var menuBarSymbol: String {
        if systemHoldEnabled || displayHoldEnabled || lidSleepDisabled == true {
            return "power.circle.fill"
        }

        return "power.circle"
    }

    func toggleSystemHold() {
        do {
            if systemHoldEnabled {
                assertions.releaseSystemIdle()
                message = "已停止阻止空闲睡眠"
            } else {
                try assertions.acquireSystemIdle(reason: "MacNoSleep menu bar")
                message = "已开启空闲不睡眠"
            }

            systemHoldEnabled = assertions.hasSystemIdle
        } catch {
            message = userFacingMessage(for: error)
        }
    }

    func toggleDisplayHold() {
        do {
            if displayHoldEnabled {
                assertions.releaseDisplayIdle()
                message = "已停止屏幕常亮"
            } else {
                try assertions.acquireDisplayIdle(reason: "MacNoSleep menu bar display")
                message = "已开启屏幕常亮"
            }

            displayHoldEnabled = assertions.hasDisplayIdle
        } catch {
            message = userFacingMessage(for: error)
        }
    }

    func toggleLidSleepDisabled() {
        guard !isChangingLidSleep else {
            return
        }

        let newValue = !(lidSleepDisabled ?? false)
        let duration = selectedLidDuration
        isChangingLidSleep = true
        message = newValue ? "等待管理员授权..." : "正在恢复正常睡眠..."

        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> (SleepDisabledStatus?, Date?, String?) in
                do {
                    let endDate: Date?

                    if newValue, let seconds = duration.seconds {
                        try PowerControl.setDisableSleepUsingAuthorizationDialog(durationSeconds: seconds)
                        endDate = Date().addingTimeInterval(TimeInterval(seconds))
                    } else {
                        try PowerControl.setDisableSleepUsingAuthorizationDialog(newValue)
                        endDate = nil
                    }

                    let status = try PowerControl.readSleepDisabledStatus()
                    return (status, endDate, nil)
                } catch {
                    return (nil, nil, SleepMenuModel.userFacingMessage(for: error))
                }
            }.value

            isChangingLidSleep = false

            if let status = result.0 {
                scheduledLidEndDate = result.1
                scheduleStatusRefresh(for: result.1)
                apply(status)
                message = successMessage(enabled: newValue, duration: duration)
            } else {
                message = result.2 ?? "修改失败"
                refreshStatus()
            }
        }
    }

    func selectLidDuration(_ duration: LidSleepDuration) {
        selectedLidDuration = duration
        UserDefaults.standard.set(duration.rawValue, forKey: Self.durationDefaultsKey)

        if lidSleepDisabled == true {
            message = "时长下次开启生效"
        } else {
            message = "合盖时长已设为 \(duration.title)"
        }
    }

    func refreshStatus() {
        do {
            apply(try PowerControl.readSleepDisabledStatus())
        } catch {
            statusText = "状态读取失败"
            message = Self.userFacingMessage(for: error)
        }
    }

    private func apply(_ status: SleepDisabledStatus) {
        lidSleepDisabled = status.isDisabled

        switch status.isDisabled {
        case true:
            if let scheduledLidEndDate {
                statusText = "合盖不睡眠至 \(Self.timeFormatter.string(from: scheduledLidEndDate))"
            } else {
                statusText = "系统睡眠已禁用"
            }
        case false:
            scheduledLidEndDate = nil
            scheduleStatusRefresh(for: nil)
            statusText = "正常睡眠已允许"
        case nil:
            statusText = "系统睡眠状态未知"
        }
    }

    private func successMessage(enabled: Bool, duration: LidSleepDuration) -> String {
        if !enabled {
            return "已恢复正常睡眠"
        }

        if duration.seconds == nil {
            return "已开启，需手动恢复"
        }

        return "已开启 \(duration.title)"
    }

    private func userFacingMessage(for error: Error) -> String {
        Self.userFacingMessage(for: error)
    }

    private nonisolated static func userFacingMessage(for error: Error) -> String {
        if let appError = error as? AppError {
            return appError.description
        }

        return error.localizedDescription
    }

    private func scheduleStatusRefresh(for endDate: Date?) {
        statusRefreshTask?.cancel()
        statusRefreshTask = nil

        guard let endDate else {
            return
        }

        let delay = max(endDate.timeIntervalSinceNow + 2, 2)
        statusRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

            if Task.isCancelled {
                return
            }

            self?.refreshStatus()
        }
    }

    private nonisolated static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}
