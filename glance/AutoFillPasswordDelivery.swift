import Foundation
import ApplicationServices

/// The synchronous write/validate/press transaction, separated from AX discovery
/// so remote failures can be exercised without a password or a native auth dialog.
@MainActor
enum AutoFillPasswordDelivery {
    enum Outcome { case submitted, indeterminate }
    enum PressResult { case submitted, rejected, indeterminate }
    enum Failure: Error { case targetChanged, writeFailed, submissionFailed, cleanupFailed }

    struct Operations {
        let isEligible: (Int) -> Bool
        let write: (String) -> AXError
        /// Uses retained field ownership, not eligibility. True means empty was
        /// confirmed, not merely that an empty-value write was sent.
        let clearRetainedField: () -> Bool
        let press: () -> PressResult
    }

    static func submit(_ bytes: Data, mayProceed: () -> Bool, operations: Operations) throws -> Outcome {
        guard mayProceed(), operations.isEligible(0),
              let text = String(data: bytes, encoding: .utf8), !text.isEmpty else {
            throw Failure.targetChanged
        }
        func abort(_ failure: Failure) throws -> Never {
            guard operations.clearRetainedField() else { throw Failure.cleanupFailed }
            throw failure
        }
        // A failed setter is not guaranteed to have rolled back its side effects.
        guard operations.write(text) == .success else { try abort(.writeFailed) }
        guard mayProceed(), operations.isEligible(text.utf16.count) else { try abort(.targetChanged) }
        switch operations.press() {
        case .submitted:
            return .submitted
        case .indeterminate:
            // The action may be in progress. Never clear or resubmit underneath it.
            return .indeterminate
        case .rejected:
            try abort(.submissionFailed)
        }
    }

    static func classifyPressResult(_ error: AXError) -> PressResult {
        switch error {
        case .success: return .submitted
        case .actionUnsupported, .illegalArgument, .invalidUIElement, .notImplemented, .apiDisabled:
            return .rejected
        default:
            // In particular, cannotComplete may be a modal callback outliving
            // the AX timeout. Generic/unknown failures carry no stronger proof.
            return .indeterminate
        }
    }
}
