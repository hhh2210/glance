import AppKit
import Observation

/// One attempt per native request. Only a verified face may release the existing
/// unlocked Glance credential; this path never opens another authentication session.
@Observable
@MainActor
final class AutoFillApprovalCoordinator {
    private(set) var statusMessage = "Waiting for an AutoFill request."
    private let scanner: FaceVerificationScanner
    private let adapter = AutoFillPromptAdapter()
    private let panel = AutoFillApprovalPanel()
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var requestID: UUID?
    private var activeTarget: AutoFillPromptAdapter.Target?
    private var attemptedTarget: AutoFillPromptAdapter.Target?

    init(scanner: FaceVerificationScanner) {
        self.scanner = scanner
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private var prerequisitesMet: Bool {
        GlanceSettings.shared.isAutoFillApprovalEnabled
            && GlanceSettings.shared.hasCompletedOnboarding
            && GlanceSettings.shared.hasAcknowledgedSecurityNotice
            && GlanceSettings.shared.livenessChecksEnabled
            && SecureCredentialManager.isSessionUnlocked
            && !FaceEnrollmentStore.shared.isLocked
            && FaceEnrollmentStore.shared.loadFailure == nil
            && !FaceEnrollmentStore.shared.activeIdentities.isEmpty
            && AutoFillPromptAdapter.isSessionUnlocked
            && NotchOverlayController.shared.phase != .onboarding
            // Face Lab lives in Settings. Don't compete with its camera or setup.
            && !NSApp.windows.contains { $0.canBecomeMain && $0.isVisible }
    }

    private func poll() {
        guard GlanceSettings.shared.isAutoFillApprovalEnabled else {
            cancel()
            attemptedTarget = nil
            return
        }
        if let attemptedTarget, !adapter.stillExists(attemptedTarget) { self.attemptedTarget = nil }
        guard prerequisitesMet else { cancel(); return }
        if let target = activeTarget {
            if !adapter.isCurrent(target) { cancel() }
            return
        }
        guard scanner.activeRequestID == nil, attemptedTarget == nil,
              SecureCredentialManager.hasStoredPassword(), let target = adapter.discover() else { return }
        attemptedTarget = target
        activeTarget = target
        let id = UUID()
        requestID = id
        task = Task { [weak self] in await self?.approve(target, requestID: id) }
    }

    private func mayContinue(_ id: UUID) -> Bool {
        requestID == id && !Task.isCancelled && prerequisitesMet
    }

    private func cancel() {
        guard let id = requestID else { return }
        requestID = nil
        task?.cancel()
        task = nil
        scanner.cancel(requestID: id)
        activeTarget = nil
        panel.dismiss()
        statusMessage = "AutoFill approval cancelled. Use the system prompt."
    }

    private func approve(_ target: AutoFillPromptAdapter.Target, requestID id: UUID) async {
        var keepsNotice = false
        defer {
            if requestID == id {
                requestID = nil
                activeTarget = nil
                task = nil
                if !keepsNotice { panel.dismiss() }
            }
        }
        guard mayContinue(id), adapter.isCurrent(target) else { return }
        panel.show(near: target.bounds) { [weak self] in self?.cancel() }
        statusMessage = "Looking for your face…"
        let result = await scanner.scan(
            requestID: id,
            timeout: TimeInterval(GlanceSettings.shared.faceDetectionSeconds),
            thresholdProvider: { GlanceSettings.shared.matchThreshold },
            shouldContinue: { [weak self] in self?.mayContinue(id) == true }
        )
        guard mayContinue(id), adapter.isCurrent(target) else { return }
        guard case .verified = result else {
            statusMessage = "Face verification did not complete. Use the system prompt."
            return
        }
        statusMessage = "Face verified. AutoFill in one second…"
        panel.update("Face verified. AutoFill in one second…")
        do { try await Task.sleep(for: .seconds(1)) }
        catch { return }
        guard mayContinue(id), adapter.isCurrent(target) else { return }
        do {
            var bytes = try await Task.detached(priority: .userInitiated) {
                try SecureCredentialManager.readPassword()
            }.value
            defer { bytes.resetBytes(in: 0..<bytes.count) }
            guard mayContinue(id), adapter.isCurrent(target) else { return }
            let outcome = try adapter.submit(bytes, to: target, mayProceed: { self.mayContinue(id) })
            // AXPress success only proves submission. It doesn't prove that the
            // requesting app accepted the credential or completed AutoFill.
            switch outcome {
            case .submitted:
                statusMessage = "Submitted to AutoFill."
            case .indeterminate:
                statusMessage = "AutoFill may still be processing. Check the system prompt."
                keepsNotice = true
                panel.showNotice(statusMessage, near: target.bounds)
            }
        } catch AutoFillPromptAdapter.DeliveryError.cleanupFailed {
            statusMessage = "Could not confirm the password field was cleared. Clear it or cancel the system prompt."
            keepsNotice = true
            panel.showNotice("Clear the password field or cancel the system prompt.", near: target.bounds)
        } catch {
            statusMessage = "AutoFill was not submitted. Use the system prompt."
        }
    }
}
