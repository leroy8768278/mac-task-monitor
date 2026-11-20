import Combine
import Foundation
import IOKit.pwr_mgt

@MainActor
final class AwakeController: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var errorMessage: String?

    private var systemAssertion: IOPMAssertionID?
    private var displayAssertion: IOPMAssertionID?

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        if enabled {
            do {
                if systemAssertion == nil { systemAssertion = try Self.acquire(.system) }
                if displayAssertion == nil { displayAssertion = try Self.acquire(.display) }
            } catch {
                let remaining = releaseAssertions()
                errorMessage = error.localizedDescription + (remaining.map { " \($0)" } ?? "")
            }
        } else {
            errorMessage = releaseAssertions()
        }
        // Leave the switch on when a release fails so the user can retry it.
        isEnabled = systemAssertion != nil || displayAssertion != nil
    }

    func stopForTermination() {
        setEnabled(false)
    }

    deinit {
        if let displayAssertion { IOPMAssertionRelease(displayAssertion) }
        if let systemAssertion { IOPMAssertionRelease(systemAssertion) }
    }

    private func releaseAssertions() -> String? {
        let displayFailure = Self.release(.display, id: &displayAssertion)
        let systemFailure = Self.release(.system, id: &systemAssertion)
        let remaining = [displayFailure, systemFailure].compactMap { $0 }
        guard !remaining.isEmpty else { return nil }
        return "仍在阻止\(remaining.joined(separator: "、"))。请再试一次关闭。"
    }

    private static func acquire(_ kind: AssertionKind) throws -> IOPMAssertionID {
        var id = IOPMAssertionID(kIOPMNullAssertionID)
        let status = IOPMAssertionCreateWithName(
            kind.rawValue as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Mac Task Monitor Keep Awake" as CFString,
            &id
        )
        guard status == kIOReturnSuccess, id != kIOPMNullAssertionID else {
            throw AssertionError(kind: kind, status: status)
        }
        return id
    }

    private static func release(_ kind: AssertionKind, id: inout IOPMAssertionID?) -> String? {
        guard let current = id else { return nil }
        let status = IOPMAssertionRelease(current)
        if status == kIOReturnSuccess || status == kIOReturnNotFound {
            id = nil
            return nil
        }
        return "\(kind.label)（\(code(status))）"
    }

    private enum AssertionKind: String {
        // The IOKit headers expose these CFSTR macros under the kIOPMAssert… names.
        case system = "PreventUserIdleSystemSleep"
        case display = "PreventUserIdleDisplaySleep"

        var label: String {
            switch self {
            case .system: "系统闲置睡眠"
            case .display: "屏幕闲置休眠"
            }
        }
    }

    private struct AssertionError: LocalizedError {
        let kind: AssertionKind
        let status: IOReturn

        var errorDescription: String? {
            status == kIOReturnSuccess
                ? "系统未返回用于阻止\(kind.label)的有效请求。"
                : "无法阻止\(kind.label)（\(AwakeController.code(status))）。"
        }
    }

    private nonisolated static func code(_ status: IOReturn) -> String {
        String(format: "0x%08X", UInt32(bitPattern: status))
    }
}
