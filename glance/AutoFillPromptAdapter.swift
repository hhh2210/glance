import AppKit
import ApplicationServices
import CryptoKit
import Security

/// A deliberately narrow adapter for Apple's AutoFill account-password prompt.
/// It never reads a text field's value, inspects a vault, or sends global keys.
@MainActor
final class AutoFillPromptAdapter {
    struct Target {
        let application: NSRunningApplication
        let window: AXUIElement
        let field: AXUIElement
        let submit: AXUIElement
        let bounds: CGRect
        let promptFingerprint: Data

        func isSame(as other: Target) -> Bool {
            application.processIdentifier == other.application.processIdentifier
                && application.launchDate == other.application.launchDate
                && CFEqual(window, other.window) && CFEqual(field, other.field)
                && CFEqual(submit, other.submit)
                && promptFingerprint == other.promptFingerprint
        }
    }

    enum DeliveryError: LocalizedError {
        case targetChanged, unsupportedField, submissionFailed, cleanupFailed
        var errorDescription: String? {
            switch self {
            case .targetChanged: return "AutoFill request changed. Use the system prompt."
            case .unsupportedField: return "This password field does not support direct filling."
            case .submissionFailed: return "AutoFill could not be submitted. Use the system prompt."
            case .cleanupFailed: return "Could not confirm the password field was cleared. Clear it or cancel the system prompt."
            }
        }
    }

    private let owners = ["com.apple.LocalAuthentication.UIAgent", "com.apple.LocalAuthenticationRemoteService"]

    func discover() -> Target? {
        guard AXIsProcessTrusted(), Self.isSessionUnlocked else { return nil }
        let eligibleTargets = owners.flatMap { bundle in
            NSRunningApplication.runningApplications(withBundleIdentifier: bundle).flatMap { app -> [Target] in
                guard hasVisibleWindow(pid: app.processIdentifier), isTrustedOwner(app) else { return [] }
                return candidates(in: app, expectedCharacters: 0)
            }
        }
        // Never choose the first of multiple eligible fields.
        return eligibleTargets.count == 1 ? eligibleTargets[0] : nil
    }

    func stillExists(_ target: Target) -> Bool {
        guard !target.application.isTerminated else { return false }
        let app = AXUIElementCreateApplication(target.application.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.1)
        // An IPC failure isn't evidence that the user closed the request. Keep
        // the one-attempt latch so a cancelled request cannot restart by itself.
        guard let windows = Self.attribute(app, kAXWindowsAttribute) as? [AXUIElement] else { return true }
        return windows.contains { CFEqual($0, target.window) }
    }

    func isCurrent(_ target: Target, expectedCharacters: Int = 0) -> Bool {
        guard !target.application.isTerminated, isTrustedOwner(target.application), Self.isSessionUnlocked else { return false }
        let current = owners.flatMap { bundle in
            NSRunningApplication.runningApplications(withBundleIdentifier: bundle).flatMap { app -> [Target] in
                guard hasVisibleWindow(pid: app.processIdentifier), isTrustedOwner(app) else { return [] }
                return candidates(in: app, expectedCharacters: expectedCharacters)
            }
        }
        return current.count == 1 && current[0].isSame(as: target)
    }

    /// Called only after face verification and the cancellable countdown. AX writes
    /// address the retained secure field directly, so a focus race cannot type into
    /// another app. Unsupported AX controls fail without a CGEvent fallback.
    @discardableResult
    func submit(_ bytes: Data, to target: Target, mayProceed: () -> Bool) throws -> AutoFillPasswordDelivery.Outcome {
        do {
            return try AutoFillPasswordDelivery.submit(bytes, mayProceed: mayProceed, operations: .init(
                isEligible: { self.isCurrent(target, expectedCharacters: $0) },
                write: { text in
                    let timeout = AXUIElementSetMessagingTimeout(target.field, 0.1)
                    guard timeout == .success else { return timeout }
                    return AXUIElementSetAttributeValue(target.field, kAXValueAttribute as CFString, text as CFString)
                },
                clearRetainedField: { self.clearRetainedField(target) },
                press: {
                    // Reads above use 20 ms. Restore an action timeout *after*
                    // validation and immediately before pressing this exact button.
                    guard AXUIElementSetMessagingTimeout(target.submit, 0.5) == .success else { return .rejected }
                    return AutoFillPasswordDelivery.classifyPressResult(
                        AXUIElementPerformAction(target.submit, kAXPressAction as CFString)
                    )
                }
            ))
        } catch let failure as AutoFillPasswordDelivery.Failure {
            switch failure {
            case .targetChanged: throw DeliveryError.targetChanged
            case .writeFailed: throw DeliveryError.unsupportedField
            case .submissionFailed: throw DeliveryError.submissionFailed
            case .cleanupFailed: throw DeliveryError.cleanupFailed
            }
        }
    }

    /// Revoking permission to submit must not revoke our ability to erase what
    /// we just wrote. This checks retained ownership only, never focus, lock state,
    /// visibility, prompt text, button enablement, or an expected character count.
    private func ownsRetainedField(_ target: Target) -> Bool {
        guard !target.application.isTerminated, isTrustedOwner(target.application) else { return false }
        let pid = target.application.processIdentifier
        var fieldPID: pid_t = 0
        var windowPID: pid_t = 0
        guard AXUIElementGetPid(target.field, &fieldPID) == .success, fieldPID == pid,
              AXUIElementGetPid(target.window, &windowPID) == .success, windowPID == pid,
              Self.attribute(target.field, kAXRoleAttribute) as? String == kAXTextFieldRole,
              Self.attribute(target.field, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole,
              let fieldWindow = Self.attribute(target.field, kAXWindowAttribute), CFEqual(fieldWindow, target.window),
              let windows = Self.attribute(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AXUIElement]
        else { return false }
        return windows.contains { CFEqual($0, target.window) }
    }

    private func clearRetainedField(_ target: Target) -> Bool {
        guard ownsRetainedField(target), AXUIElementSetMessagingTimeout(target.field, 0.1) == .success else { return false }
        _ = AXUIElementSetAttributeValue(target.field, kAXValueAttribute as CFString, "" as CFString)
        // Even the clear can time out. Confirm absence without reading AXValue.
        return ownsRetainedField(target) && Self.attribute(target.field, kAXNumberOfCharactersAttribute) as? Int == 0
    }

    /// Missing CGSession data is unknown, not an unlocked desktop.
    static var isSessionUnlocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              let onConsole = session[kCGSessionOnConsoleKey as String] as? Bool,
              let loginDone = session[kCGSessionLoginDoneKey as String] as? Bool,
              onConsole, loginDone else { return false }
        // This key is absent in an unlocked session on macOS; a complete console
        // session plus no lock flag is the unlocked state, not a missing dictionary.
        return (session["CGSSessionScreenIsLocked"] as? Bool) != true
    }

    private func isTrustedOwner(_ app: NSRunningApplication) -> Bool {
        guard let bundle = app.bundleIdentifier, owners.contains(bundle), !app.isTerminated else { return false }
        var code: SecCode?
        let attributes = [kSecGuestAttributePid as String: app.processIdentifier] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        let rule = "anchor apple and identifier \"\(bundle)\""
        guard SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    private func candidates(in app: NSRunningApplication, expectedCharacters: Int) -> [Target] {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.1)
        guard let windows = Self.attribute(root, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        let snapshotDeadline = ContinuousClock.now + .milliseconds(120)
        return windows.prefix(6).compactMap { window in
            guard ContinuousClock.now < snapshotDeadline else { return nil }
            guard let bounds = Self.bounds(of: window), isOnScreen(bounds, pid: app.processIdentifier) else { return nil }
            var texts: [String] = []
            var buttons: [(String, AXUIElement)] = []
            var fields: [AXUIElement] = []
            var visited = 0
            let deadline = ContinuousClock.now + .milliseconds(80)
            @MainActor func walk(_ element: AXUIElement, depth: Int) {
                guard depth <= 12, visited < 160, ContinuousClock.now < deadline else { return }
                visited += 1
                let role = Self.attribute(element, kAXRoleAttribute) as? String
                let subrole = Self.attribute(element, kAXSubroleAttribute) as? String
                if role == kAXStaticTextRole {
                    // Static labels only; never ask AXTextField for AXValue.
                    texts.append(Self.attribute(element, kAXValueAttribute) as? String ?? "")
                } else if role == kAXButtonRole {
                    buttons.append((Self.attribute(element, kAXTitleAttribute) as? String ?? "", element))
                } else if role == kAXTextFieldRole, subrole == kAXSecureTextFieldSubrole {
                    fields.append(element)
                }
                if let children = Self.attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                    for child in children.prefix(40) { walk(child, depth: depth + 1) }
                }
            }
            walk(window, depth: 0)
            guard ContinuousClock.now < deadline else { return nil }
            guard fields.count == 1, let field = fields.first,
                  let count = Self.attribute(field, kAXNumberOfCharactersAttribute) as? Int,
                  count == expectedCharacters else { return nil }
            var fieldPID: pid_t = 0
            guard AXUIElementGetPid(field, &fieldPID) == .success, fieldPID == app.processIdentifier else { return nil }
            var settable = DarwinBoolean(false)
            AXUIElementSetMessagingTimeout(field, 0.02)
            let editable = AXUIElementIsAttributeSettable(field, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
            let evidence = AutoFillPromptEvidence(
                staticTexts: texts, buttonTitles: buttons.map(\.0), secureFieldCount: fields.count,
                isFieldEmpty: true, // Exact expected length was checked above (zero during discovery).
                isFieldEditable: editable && Self.attribute(field, kAXEnabledAttribute) as? Bool == true,
                isFieldFocused: Self.attribute(field, kAXFocusedAttribute) as? Bool == true && Self.hasSystemFocus(field),
                isAppleSignedOwner: true, isOnScreen: true, sessionIsUnlocked: Self.isSessionUnlocked,
                belongsToCurrentUser: AutoFillPromptPolicy.mentionsCurrentUser(in: texts, aliases: [NSUserName(), NSFullUserName()])
            )
            guard AutoFillPromptPolicy.accepts(evidence) else { return nil }
            let submitButtons = buttons.filter { ["autofill", "自动填充", "自動填寫", "自動填充"].contains($0.0.lowercased()) }
            guard submitButtons.count == 1, let submit = submitButtons.first?.1 else { return nil }
            // The native button may be disabled until a password is present.
            if expectedCharacters > 0, Self.attribute(submit, kAXEnabledAttribute) as? Bool != true { return nil }
            let labels = texts.map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }.joined(separator: "\n")
            let fingerprint = Data(SHA256.hash(data: Data(labels.utf8)))
            return Target(application: app, window: window, field: field, submit: submit, bounds: bounds, promptFingerprint: fingerprint)
        }
    }

    private func hasVisibleWindow(pid: pid_t) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return false }
        return windows.contains { $0[kCGWindowOwnerPID as String] as? pid_t == pid }
    }

    private func isOnScreen(_ bounds: CGRect, pid: pid_t) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return false }
        return windows.contains { info in
            guard info[kCGWindowOwnerPID as String] as? pid_t == pid,
                  let dictionary = info[kCGWindowBounds as String] as? [String: Any],
                  let other = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else { return false }
            return abs(bounds.minX - other.minX) < 2 && abs(bounds.minY - other.minY) < 2
                && abs(bounds.width - other.width) < 2 && abs(bounds.height - other.height) < 2
        }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        // AX timeouts are per object, not inherited by its children. Bound every
        // read so an unresponsive authentication agent cannot freeze Cancel.
        AXUIElementSetMessagingTimeout(element, 0.02)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func hasSystemFocus(_ field: AXUIElement) -> Bool {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.1)
        guard let focused = attribute(system, kAXFocusedUIElementAttribute) else { return false }
        return CFEqual(focused, field)
    }

    private static func bounds(of window: AXUIElement) -> CGRect? {
        guard let position = attribute(window, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(window, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
}
