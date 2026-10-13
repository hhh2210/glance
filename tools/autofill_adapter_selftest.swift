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
        print("AutoFill adapter self-test: \(checks) checks passed (binding and rejection only; no live dialog).")
    }
}
