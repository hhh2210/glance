import AppKit
import ApplicationServices

/// Exercises production target binding without opening windows, reading a
/// credential, or addressing any other process's controls.
@main
struct AutoFillAdapterSelfTest {
    @MainActor static func main() throws {
        let app = NSRunningApplication.current
        let element = AXUIElementCreateApplication(app.processIdentifier)
        let other = AXUIElementCreateSystemWide()
        let fingerprint = Data("public prompt fixture".utf8)
        let original = AutoFillPromptAdapter.Target(
            application: app, window: element, field: element, submit: element,
            bounds: .zero, promptFingerprint: fingerprint
        )
        var checks = 0
        func expect(_ value: Bool, _ message: String) {
            precondition(value, message)
            checks += 1
        }
        expect(original.isSame(as: original), "Same request must remain bound")
        for replacement in [
            AutoFillPromptAdapter.Target(application: app, window: element, field: element, submit: element, bounds: .zero, promptFingerprint: Data("new request".utf8)),
            AutoFillPromptAdapter.Target(application: app, window: other, field: element, submit: element, bounds: .zero, promptFingerprint: fingerprint),
            AutoFillPromptAdapter.Target(application: app, window: element, field: other, submit: element, bounds: .zero, promptFingerprint: fingerprint),
            AutoFillPromptAdapter.Target(application: app, window: element, field: element, submit: other, bounds: .zero, promptFingerprint: fingerprint)
        ] {
            expect(!original.isSame(as: replacement), "Changed request/control must invalidate a face result")
        }
        let adapter = AutoFillPromptAdapter()
        for proceed in [false, true] {
            do {
                try adapter.submit(Data("public fixture only".utf8), to: original, mayProceed: { proceed })
                preconditionFailure("Cancelled or non-Apple request must never be submitted")
            } catch AutoFillPromptAdapter.DeliveryError.targetChanged {
                checks += 1
            }
        }
        checks += try deliveryChecks()
        print("AutoFill adapter self-test: \(checks) checks passed (binding and simulated delivery; no live dialog or credential).")
    }

    @MainActor private static func deliveryChecks() throws -> Int {
        var checks = 0
        func expect(_ value: Bool, _ message: String) {
            precondition(value, message)
            checks += 1
        }
        func expectFailure(_ expected: AutoFillPasswordDelivery.Failure, fixture: DeliveryFixture) {
            do {
                _ = try fixture.submit()
                preconditionFailure("Expected a simulated delivery failure")
            } catch let actual as AutoFillPasswordDelivery.Failure {
                switch (actual, expected) {
                case (.targetChanged, .targetChanged), (.writeFailed, .writeFailed),
                     (.submissionFailed, .submissionFailed), (.cleanupFailed, .cleanupFailed):
                    checks += 1
                default:
                    preconditionFailure("Wrong simulated delivery failure")
                }
            } catch {
                preconditionFailure("Unexpected simulated delivery error type")
            }
        }

        // Timeout/transport errors do not establish whether AXPress was delivered.
        // Unlisted errors must fail closed as indeterminate, not as safe-to-retry.
        for error: AXError in [.success, .actionUnsupported, .illegalArgument,
                              .invalidUIElement, .notImplemented, .apiDisabled,
                              .cannotComplete, .failure, .attributeUnsupported,
                              .notificationUnsupported, .noValue, .parameterizedAttributeUnsupported,
                              .notEnoughPrecision] {
            let result = AutoFillPasswordDelivery.classifyPressResult(error)
            switch error {
            case .success:
                if case .submitted = result { checks += 1 }
                else { preconditionFailure("Successful AXPress must be classified as submitted") }
            case .actionUnsupported, .illegalArgument, .invalidUIElement, .notImplemented, .apiDisabled:
                if case .rejected = result { checks += 1 }
                else { preconditionFailure("Known AXPress rejection must permit cleanup") }
            default:
                if case .indeterminate = result { checks += 1 }
                else { preconditionFailure("Uncertain AXPress must not be treated as definite rejection") }
            }
        }

        // Initial rejection owns no field contents and must never clear anything.
        for cause in ["cancelled", "ineligible"] {
            let fixture = DeliveryFixture()
            if cause == "cancelled" { fixture.proceed = false }
            else { fixture.isFieldFocused = false }
            expectFailure(.targetChanged, fixture: fixture)
            expect(fixture.writeCount == 0 && fixture.pressCount == 0 && fixture.clearCount == 0,
                   "Pre-write rejection must have no delivery side effects")
        }

        // Losing eligibility after writing must not prevent cleanup of the
        // retained original field. This is separate from eligibility to submit.
        for cause in ["focus", "session", "body"] {
            let fixture = DeliveryFixture()
            fixture.afterWrite = {
                switch cause {
                case "focus": $0.isFieldFocused = false
                case "session": $0.sessionIsUnlocked = false
                default: $0.bodyMatches = false
                }
            }
            expectFailure(.targetChanged, fixture: fixture)
            expect(fixture.events == ["proceed", "eligible:0", "write", "proceed",
                                      "eligible:\(fixture.expectedLength)", "clear"],
                   "Post-write \(cause) change must clean without reusing eligibility")
            expect(fixture.fieldValue.isEmpty && fixture.clearCount == 1,
                   "Post-write \(cause) change must leave the retained field empty")
            expect(fixture.writeCount == 1 && fixture.pressCount == 0,
                   "Post-write \(cause) change must not submit or repeat the write")
        }

        let cancelled = DeliveryFixture()
        cancelled.afterWrite = { $0.proceed = false }
        expectFailure(.targetChanged, fixture: cancelled)
        expect(cancelled.events == ["proceed", "eligible:0", "write", "proceed", "clear"],
               "Cancellation after write must clear without requiring eligibility")
        expect(cancelled.fieldValue.isEmpty && cancelled.clearCount == 1 && cancelled.pressCount == 0,
               "Cancelled delivery must neither leave text nor submit")

        let uncertainWrite = DeliveryFixture()
        // A failing AX setter can still have changed the retained field.
        uncertainWrite.writeResult = .cannotComplete
        expectFailure(.writeFailed, fixture: uncertainWrite)
        expect(uncertainWrite.events == ["proceed", "eligible:0", "write", "clear"],
               "An uncertain write must attempt cleanup directly")
        expect(uncertainWrite.fieldValue.isEmpty && uncertainWrite.clearCount == 1 && uncertainWrite.pressCount == 0,
               "An uncertain write must not submit or leave fixture text")

        for cause in ["target", "write", "press"] {
            let fixture = DeliveryFixture()
            fixture.clearSucceeds = false
            switch cause {
            case "target": fixture.afterWrite = { $0.bodyMatches = false }
            case "write": fixture.writeResult = .cannotComplete
            default: fixture.pressResult = .rejected
            }
            expectFailure(.cleanupFailed, fixture: fixture)
            expect(fixture.clearCount == 1 && fixture.fieldValue == fixture.fixtureText,
                   "Failed cleanup must be reported without pretending the field was cleared")
            expect(fixture.writeCount == 1 && fixture.pressCount == (cause == "press" ? 1 : 0),
                   "Cleanup failure must not trigger a second delivery attempt")
        }

        let unsupportedPress = DeliveryFixture()
        unsupportedPress.pressResult = .rejected
        expectFailure(.submissionFailed, fixture: unsupportedPress)
        expect(unsupportedPress.events == ["proceed", "eligible:0", "write", "proceed",
                                          "eligible:\(unsupportedPress.expectedLength)", "press", "clear"],
               "A definite press failure must clear the original field")
        expect(unsupportedPress.fieldValue.isEmpty && unsupportedPress.clearCount == 1 && unsupportedPress.pressCount == 1,
               "A definite press failure must clean exactly once without retry")

        let uncertainPress = DeliveryFixture()
        uncertainPress.pressResult = .indeterminate
        switch try uncertainPress.submit() {
        case .indeterminate: checks += 1
        case .submitted: preconditionFailure("An uncertain press is not verified submission")
        }
        expect(uncertainPress.events == ["proceed", "eligible:0", "write", "proceed",
                                        "eligible:\(uncertainPress.expectedLength)", "press"],
               "An uncertain press must not clear or retry an action that may have happened")
        expect(uncertainPress.clearCount == 0 && uncertainPress.writeCount == 1 && uncertainPress.pressCount == 1,
               "An uncertain press must have exactly one write and one press")
        expect(uncertainPress.fieldValue == uncertainPress.fixtureText,
               "An uncertain press must leave cleanup to the caller's indeterminate handling")

        let success = DeliveryFixture()
        switch try success.submit() {
        case .submitted: checks += 1
        case .indeterminate: preconditionFailure("A successful press must report submitted")
        }
        expect(success.events == ["proceed", "eligible:0", "write", "proceed",
                                 "eligible:\(success.expectedLength)", "press"],
               "Normal delivery must recheck the expected UTF-16 length before one press")
        expect(success.writeCount == 1 && success.pressCount == 1 && success.clearCount == 0,
               "Normal delivery must write and submit once")
        expect(success.fieldValue == success.fixtureText, "Normal delivery preserves the supplied public fixture")
        expect(success.expectedLength != success.fixtureText.count,
               "The non-ASCII fixture must distinguish UTF-16 length from character count")
        return checks
    }
}

/// All callbacks operate on this in-memory public fixture. No AX actions, other
/// processes, windows or stored credentials participate in these scenarios.
@MainActor
private final class DeliveryFixture {
    let fixtureText = "public-🧪-fixture"
    var expectedLength: Int { fixtureText.utf16.count }
    var fieldValue = ""
    var proceed = true
    var isFieldFocused = true
    var sessionIsUnlocked = true
    var bodyMatches = true
    var clearSucceeds = true
    var writeResult: AXError = .success
    var pressResult: AutoFillPasswordDelivery.PressResult = .submitted
    var afterWrite: ((DeliveryFixture) -> Void)?
    private(set) var events: [String] = []
    private(set) var writeCount = 0
    private(set) var clearCount = 0
    private(set) var pressCount = 0

    func submit() throws -> AutoFillPasswordDelivery.Outcome {
        try AutoFillPasswordDelivery.submit(
            Data(fixtureText.utf8),
            mayProceed: {
                self.events.append("proceed")
                return self.proceed
            },
            operations: AutoFillPasswordDelivery.Operations(
                isEligible: { expectedLength in
                    self.events.append("eligible:\(expectedLength)")
                    return self.isFieldFocused && self.sessionIsUnlocked && self.bodyMatches
                        && self.fieldValue.utf16.count == expectedLength
                },
                write: { value in
                    self.events.append("write")
                    self.writeCount += 1
                    self.fieldValue = value
                    self.afterWrite?(self)
                    return self.writeResult
                },
                clearRetainedField: {
                    self.events.append("clear")
                    self.clearCount += 1
                    guard self.clearSucceeds else { return false }
                    self.fieldValue = ""
                    return true
                },
                press: {
                    self.events.append("press")
                    self.pressCount += 1
                    return self.pressResult
                }
            )
        )
    }
}
