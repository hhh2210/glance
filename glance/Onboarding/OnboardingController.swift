//
//  OnboardingController.swift
//  glance
//
//  State machine behind the notch-hosted guided onboarding flow: permissions, guided
//  nine-pose face enrollment, and password setup. Reuses the same camera/detection/
//  embedding/storage pieces as the Face Lab debug tab rather than reimplementing them.
//
//  Still not milestone G: finishing onboarding stores an encrypted password and a face
//  template, but nothing here triggers an unlock.
//

import Foundation
import Observation
import AVFoundation
import AppKit
import SwiftUI

/// `String`-backed so `GlanceSettings.onboardingResumeStep` can persist it directly by name.
enum OnboardingStep: String, CaseIterable {
    case intro
    case permissions
    case securityNotice
    case preSetup
    case selectCamera
    case enroll
    case name
    case password
    case complete

    var previous: OnboardingStep? {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self), index > 0 else { return nil }
        return all[index - 1]
    }

    /// Whether this step shows the Back/primary button pair; enroll is close-control
    /// only, and complete/intro have just one side.
    var showsBackButton: Bool {
        switch self {
        case .securityNotice, .permissions, .preSetup, .selectCamera, .name, .password: return true
        case .intro, .enroll, .complete: return false
        }
    }

    /// Where a first-run flow should resume if the app quit on this step. `.enroll`,
    /// `.name`, and `.password` all depend on in-memory state a fresh launch doesn't
    /// have, so they collapse back to `.preSetup` rather than resuming into a step
    /// whose prerequisites no longer exist.
    var resumeTarget: OnboardingStep {
        switch self {
        case .enroll, .name, .password: return .preSetup
        case .intro, .securityNotice, .permissions, .preSetup, .selectCamera, .complete: return self
        }
    }
}

enum CameraPermissionState {
    case notDetermined
    case granted
    case denied
}

@Observable
@MainActor
final class OnboardingController {
    let camera = CameraManager()
    let pipeline = FaceRecognitionPipeline()
    private let store = FaceEnrollmentStore.shared
    private let sweepWindow = EnrollmentSweepWindowController()

    /// Persists the resume point for a true first-run flow on every step change, so
    /// `AppDelegate` can drop a relaunched, mid-onboarding user back where they left off.
    /// Settings-triggered flows never touch this.
    private(set) var step: OnboardingStep = .intro {
        didSet {
            guard isFirstRunFlow else { return }
            if step == .complete {
                GlanceSettings.shared.hasCompletedOnboarding = true
                // Normal onboarding now passes through `.securityNotice` on its own —
                // completing it here means the standalone post-update notice never needs to.
                GlanceSettings.shared.hasAcknowledgedSecurityNotice = true
                GlanceSettings.shared.onboardingResumeStep = nil
            } else {
                GlanceSettings.shared.onboardingResumeStep = step.resumeTarget
            }
        }
    }

    /// Fires exactly once, after the "You're all set" screen dismisses — either the true
    /// first-run flow (so `AppDelegate` can open Settings only once onboarding UI is gone)
    /// or the standalone post-update notice (so it can resume startup). `nil` otherwise.
    var onFirstRunComplete: (() -> Void)?

    /// True when started by `startEnrollmentOnly()` — shows only the guided pose-capture
    /// step and saves samples directly instead of continuing to the password step.
    private let isEnrollmentOnly: Bool

    /// True when started by `startPasswordOnly()` — jumps straight to `.password` and
    /// treats Back as "cancel" rather than a setup flow that isn't running.
    private let isPasswordOnly: Bool

    /// True when started by `startPostUpdateNotice()` — a standalone replay of just the
    /// security-notice step for users who completed onboarding before it existed. Skips
    /// straight to `.complete` on acknowledgment; every other step is unreachable. Read by
    /// `SecurityNoticeStepView` to swap its Back button for "No thanks."
    let isPostUpdateNotice: Bool

    /// True only for the genuine first-run flow (also true when replayed via Face Lab's
    /// "Start Onboarding" debug button). Gates whether `step`'s `didSet` persists a resume point.
    private var isFirstRunFlow: Bool { !isEnrollmentOnly && !isPasswordOnly && !isPostUpdateNotice }

    /// Whether the intro's one-time light sweep already played this session. Lives here
    /// rather than as `@State` on `IntroStepView` because that view is torn down and
    /// recreated whenever navigation leaves and returns to `.intro`.
    private var hasPlayedIntroSweep = false

    /// Plays the intro screen's one-time top-to-bottom light sweep full-screen via the
    /// same `sweepWindow` guided enrollment uses. No-op after the first call this session.
    func playIntroSweepIfNeeded() {
        guard !hasPlayedIntroSweep else { return }
        hasPlayedIntroSweep = true
        sweepWindow.presentOnce(direction: .down)
    }

    /// Who this run is enrolling. Recapture is keyed by `id` rather than name so the
    /// naming step can rename an identity without orphaning it under its old name.
    enum EnrollmentTarget: Equatable {
        case newIdentity
        case replacing(UUID)

        var identityID: UUID? {
            if case .replacing(let id) = self { return id }
            return nil
        }
    }

    private let enrollmentTarget: EnrollmentTarget

    enum NavDirection { case forward, backward }
    /// Which way the step just changed — read by OnboardingNotchView to
    /// pick the scroll direction for the blur transition.
    private(set) var navDirection: NavDirection = .forward

    /// Entry point used by Face Lab's "Start Onboarding" button, and by `AppDelegate` at
    /// first launch and whenever the user tries to reach Settings before onboarding is done.
    ///
    /// - Parameter resumingAt: where a previously-quit first-run flow left off, or `nil`
    ///   to start fresh at `.intro`. `.permissions` is the one resumable step with a side
    ///   effect (live polling) that jumping straight past `advance()` would otherwise skip.
    /// - Parameter onFirstRunComplete: see the property of the same name.
    static func startFlow(resumingAt step: OnboardingStep? = nil, onFirstRunComplete: (() -> Void)? = nil) {
        let controller = OnboardingController()
        controller.pendingName = defaultName
        controller.onFirstRunComplete = onFirstRunComplete
        if let step, step != .intro {
            controller.step = step
            if step == .permissions {
                controller.startPermissionsPolling()
            }
        }
        NotchOverlayController.shared.presentOnboarding(controller)
    }

    /// Entry point used by Settings' "Set up Face Unlock" / "Redo Face Enrollment" — presents
    /// the guided pose-capture plus naming step and saves directly once done.
    ///
    /// The Your Face page is still single-identity, so this keeps targeting
    /// `identities.first`: "redo" replaces it in place, or enrolls someone new.
    static func startEnrollmentOnly() {
        Task { @MainActor in
            guard await unlockForEnrollment(reason: "Authenticate to re-enroll your face") else { return }
            let store = FaceEnrollmentStore.shared
            store.reloadIfUnlocked()
            let existing = store.identities.first
            present(
                target: existing.map { .replacing($0.id) } ?? .newIdentity,
                prefillName: existing?.name ?? defaultName
            )
        }
    }

    /// Entry point used by Face Lab's "Add Identity" — always enrolls a *new* person
    /// alongside whoever is already enrolled; name starts empty rather than `defaultName`.
    static func startAddIdentity() {
        Task { @MainActor in
            guard await unlockForEnrollment(reason: "Authenticate to enroll another face") else { return }
            FaceEnrollmentStore.shared.reloadIfUnlocked()
            present(target: .newIdentity, prefillName: "")
        }
    }

    /// Entry point used by Face Lab's per-identity "Recapture" — replaces that identity's
    /// samples wholesale, keeping its id and enrollment date.
    static func startRecapture(of identity: FaceIdentity) {
        Task { @MainActor in
            guard await unlockForEnrollment(reason: "Authenticate to re-enroll this face") else { return }
            FaceEnrollmentStore.shared.reloadIfUnlocked()
            present(target: .replacing(identity.id), prefillName: identity.name)
        }
    }

    /// Enrollment-only flows persist as soon as naming is confirmed, so Touch ID has to
    /// happen up front — there's no later password step to unlock the session.
    private static func unlockForEnrollment(reason: String) async -> Bool {
        guard !SecureCredentialManager.isSessionUnlocked else { return true }
        do {
            try await Task.detached(priority: .userInitiated) {
                try SecureCredentialManager.unlockSession(reason: reason)
            }.value
            return true
        } catch {
            return false
        }
    }

    private static func present(target: EnrollmentTarget, prefillName: String) {
        let controller = OnboardingController(isEnrollmentOnly: true, enrollmentTarget: target)
        controller.pendingName = prefillName
        NotchOverlayController.shared.presentOnboarding(controller)
    }

    /// Entry point used by Settings' "Change password" — presents only the password step,
    /// reusing the same field, validation and save path as first-run setup.
    ///
    /// No Touch ID prompt here: the only caller already has a live session, and
    /// `finish(password:)` re-asserts that anyway.
    static func startPasswordOnly() {
        Task { @MainActor in
            let controller = OnboardingController(isPasswordOnly: true)
            NotchOverlayController.shared.presentOnboarding(controller)
        }
    }

    /// Entry point used by `AppDelegate` at launch for users who completed onboarding
    /// before the security-notice step existed — a standalone replay of just that step, so
    /// they still see it once. Everything else is already done, so acknowledging it jumps
    /// straight to `.complete` (see `advance()`) rather than resuming the full flow.
    static func startPostUpdateNotice(onComplete: (() -> Void)? = nil) {
        let controller = OnboardingController(isPostUpdateNotice: true)
        controller.onFirstRunComplete = onComplete
        NotchOverlayController.shared.presentOnboarding(controller)
    }

    // MARK: - Panel sizing (read by NotchOverlayView)

    /// Read fresh off the preferred screen each time rather than cached, so it stays
    /// correct across a display change mid-flow.
    private var currentPanelStyle: NotchPanelStyle {
        NotchGeometry.preferredScreen().map(NotchGeometry.forScreen)?.style ?? .notch
    }

    var panelSize: CGSize { OnboardingMetrics.panelSize(for: step, style: currentPanelStyle) }
    var panelBottomRadius: CGFloat { OnboardingMetrics.panelBottomRadius(for: step) }

    // MARK: - Permissions

    private(set) var accessibilityGranted = false
    private(set) var cameraPermission: CameraPermissionState = .notDetermined
    var bothPermissionsGranted: Bool { accessibilityGranted && cameraPermission == .granted }

    private var permissionsPollTask: Task<Void, Never>?

    // MARK: - Enrollment

    private(set) var enrollmentCapture = EnrollmentCaptureState()
    private var enrollmentGeneration = UUID()
    private var enrollmentActive = false
    private var isProcessingFrame = false
    private var enrollmentMinimumFaceWidth: Float {
        max(FaceRecognitionPipeline.minimumProminentFaceWidth, 0.2)
    }

    var currentPose: EnrollmentPose? { enrollmentCapture.currentPose }
    var currentPoseIndex: Int { enrollmentCapture.poseIndex }
    var capturedForCurrentPose: Int { enrollmentCapture.samplesForPose }
    var enrollmentComplete: Bool { enrollmentCapture.phase == .complete }
    var isTooFar: Bool { enrollmentCapture.phase == .blocked(.tooFar) }

    /// Only captured directions stay lit; the separate inner ring shows the hold.
    private(set) var capturedPoses: Set<EnrollmentPose> = []
    private(set) var centerPulseTick = 0
    private(set) var guideVisible = false
    private(set) var cameraPreviewVisible = true
    private(set) var showCheckmark = false

    private struct CollectedSample {
        let embedding: [Float]
        let pose: EnrollmentPose
        let quality: Float?
        let capturedAt: Date
    }
    /// Samples remain in memory until naming/saving; interrupted holds keep them.
    private var collectedSamples: [CollectedSample] = []

    /// Sweep only toward the axis still missing; never encourage more turning while
    /// holding, capturing or already beyond the pose envelope.
    var turnGuidance: EnrollmentPose? {
        switch enrollmentCapture.phase {
        case .blocked(.adjustPose): currentPose
        case .blocked(.adjustYaw(.left)): .left
        case .blocked(.adjustYaw(.right)): .right
        case .blocked(.adjustPitch(.up)): .top
        case .blocked(.adjustPitch(.down)): .bottom
        default: nil
        }
    }

    private enum EnrollFrameOutcome: Sendable {
        case noFace
        case tooFar
        case alignmentFailed
        case processingFailed
        case ready(FaceRecognitionResult)
    }

    var overallEnrollmentProgress: Double {
        Double(enrollmentCapture.totalSamples)
            / Double(EnrollmentPose.allCases.count * EnrollmentCaptureState.samplesPerPose)
    }

    // MARK: - Naming

    /// Bound directly by `NameStepView`; pre-filled by whichever entry point started the flow.
    var pendingName: String = ""
    private(set) var nameError: String?

    /// Naming is the last input in an add/recapture flow, but only the
    /// halfway point of first-run setup, where the password still follows.
    var nameStepPrimaryTitle: String { isEnrollmentOnly ? "Save" : "Continue" }

    // MARK: - Password

    private(set) var passwordError: String?
    private(set) var isSavingPassword = false

    init(
        isEnrollmentOnly: Bool = false,
        isPasswordOnly: Bool = false,
        isPostUpdateNotice: Bool = false,
        enrollmentTarget: EnrollmentTarget = .newIdentity
    ) {
        self.isEnrollmentOnly = isEnrollmentOnly
        self.isPasswordOnly = isPasswordOnly
        self.isPostUpdateNotice = isPostUpdateNotice
        self.enrollmentTarget = enrollmentTarget
        observeFrames()
        if isEnrollmentOnly {
            step = .enroll
            // Deferred a tick for the same reason `advance()` defers it — see comment there.
            Task { @MainActor [weak self] in self?.beginEnrollment() }
        } else if isPasswordOnly {
            // No deferral needed: the password step starts nothing heavy.
            step = .password
        } else if isPostUpdateNotice {
            step = .securityNotice
        }
    }

    // MARK: - Navigation

    func advance() {
        navDirection = .forward
        let leavingStep = step
        withAnimation(OnboardingMetrics.stepAnimation) {
            if isPostUpdateNotice {
                // The only transition this flow has: notice seen, done.
                step = .complete
            } else {
                switch step {
                case .intro: step = .permissions
                case .permissions: step = .securityNotice
                case .securityNotice: step = .preSetup
                case .preSetup: step = .selectCamera
                case .selectCamera: step = .enroll
                case .enroll: break // advances automatically on completion
                case .name: break // handled by confirmName()
                case .password: break // handled by finish(password:)
                case .complete: break
                }
            }
        }
        if leavingStep == .permissions { stopPermissionsPolling() }
        switch step {
        case .permissions: startPermissionsPolling()
        case .enroll:
            // Deferred a tick so the heavy camera start doesn't land in the same runloop
            // turn as the panel-resize transition, stealing frames from the spring animation.
            Task { @MainActor [weak self] in self?.beginEnrollment() }
        case .complete where isPostUpdateNotice:
            GlanceSettings.shared.hasAcknowledgedSecurityNotice = true
            scheduleCompletionDismiss()
        default: break
        }
    }

    /// "No thanks" on the post-update notice. Declining isn't a real option — the app
    /// requires acknowledgment before it'll run — so this quits rather than dismissing back
    /// into use.
    func declinePostUpdateNotice() {
        NSApp.terminate(nil)
    }

    /// Steps backward. The enroll close control also lands here: a retreat to pre-setup
    /// in the full setup flow, a cancel in add/recapture.
    func back() {
        navDirection = .backward
        // No earlier step to return to in the password-only flow — Back is a plain cancel.
        if isPasswordOnly {
            teardown()
            NotchOverlayController.shared.dismissOnboarding()
            return
        }
        switch step {
        case .enroll where isEnrollmentOnly:
            // Nothing precedes enrollment in add/recapture flows — Close is a cancel.
            teardown()
            NotchOverlayController.shared.dismissOnboarding()
        case .enroll:
            // Camera has to stop here; `.enroll` is the only step that owns it.
            resetEnrollmentState()
            camera.stop()
            sweepWindow.dismiss()
            withAnimation(OnboardingMetrics.stepAnimation) { step = .selectCamera }
        case .password:
            // Deliberately *without* resetting: samples and typed name survive so a typo
            // fix doesn't mean re-doing nine poses.
            nameError = nil
            withAnimation(OnboardingMetrics.stepAnimation) { step = .name }
        case .name where isEnrollmentOnly:
            // Nothing precedes naming in add/recapture flows — Back is a cancel.
            teardown()
            NotchOverlayController.shared.dismissOnboarding()
        case .name:
            // `.enroll` can't be resumed halfway, so backing past it discards the capture.
            resetEnrollmentState()
            withAnimation(OnboardingMetrics.stepAnimation) { step = .selectCamera }
        default:
            guard let previous = step.previous else { return }
            withAnimation(OnboardingMetrics.stepAnimation) { step = previous }
            if step == .permissions {
                startPermissionsPolling()
            }
        }
    }

    /// Note `pendingName` deliberately survives — no reason to make the user retype it.
    private func resetEnrollmentState() {
        enrollmentActive = false
        enrollmentGeneration = UUID()
        enrollmentCapture = EnrollmentCaptureState()
        collectedSamples = []
        nameError = nil
        capturedPoses = []
        guideVisible = false
        cameraPreviewVisible = true
        showCheckmark = false
        passwordError = nil
    }

    private func beginEnrollment() {
        guard step == .enroll else { return }
        enrollmentGeneration = UUID()
        enrollmentActive = true
        enrollmentCapture = EnrollmentCaptureState()
        guideVisible = true
        cameraPreviewVisible = true
        showCheckmark = false
        sweepWindow.present(for: self)
        let generation = enrollmentGeneration
        Task {
            guard enrollmentActive, enrollmentGeneration == generation else { return }
            await camera.start()
            if !enrollmentActive { camera.stop() }
        }
    }

    /// Invalidating the generation also discards in-flight recognition/completion work.
    func teardown() {
        enrollmentActive = false
        enrollmentGeneration = UUID()
        stopPermissionsPolling()
        camera.stop()
        sweepWindow.dismiss()
    }

    // MARK: - Permissions

    private func startPermissionsPolling() {
        refreshPermissions()
        permissionsPollTask?.cancel()
        permissionsPollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self.refreshPermissions()
            }
        }
    }

    private func stopPermissionsPolling() {
        permissionsPollTask?.cancel()
        permissionsPollTask = nil
    }

    private func refreshPermissions() {
        accessibilityGranted = KeystrokeInjector.isAccessibilityTrusted()
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: cameraPermission = .granted
        case .notDetermined: cameraPermission = .notDetermined
        default: cameraPermission = .denied
        }
    }

    private var hasPromptedAccessibility = false

    func grantAccessibility() {
        guard !hasPromptedAccessibility else {
            openSystemSettings(pane: "Privacy_Accessibility")
            return
        }
        hasPromptedAccessibility = true
        KeystrokeInjector.promptForAccessibility()
        refreshPermissions()
    }

    func grantCamera() {
        Task {
            if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
                refreshPermissions()
            } else {
                openSystemSettings(pane: "Privacy_Camera")
            }
        }
    }

    private func openSystemSettings(pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Camera selection

    /// Devices offered by the picker — refreshed when the step appears, since a camera
    /// can be plugged in after the app launched.
    private(set) var cameraDevices: [CameraDevice] = []

    func refreshCameraDevices() {
        cameraDevices = CameraDeviceCatalog.availableDevices()
    }

    /// Text shown inside the pill: the explicitly chosen device's name, or the resolved
    /// system default's name suffixed "(Default)" when nothing's been picked yet.
    var cameraSelectionLabel: String {
        if let id = GlanceSettings.shared.defaultCameraID,
           let device = cameraDevices.first(where: { $0.id == id }) {
            return device.name
        }
        guard let name = resolveDefaultCameraDevice()?.localizedName else { return "System default" }
        return "\(name) (Default)"
    }

    /// Writes the pick straight into Settings — the same `defaultCameraID` the Camera
    /// settings page and `CameraDeviceCatalog.resolvedDevice()` read — then re-checks
    /// whether the panel should follow the built-in display.
    func selectCamera(id: String?) {
        GlanceSettings.shared.defaultCameraID = id
        applyDisplayPinForCameraSelection()
    }

    /// Pins the Face Unlock panel to the MacBook's own screen while the built-in camera
    /// is selected (auto-resolved or explicitly chosen), and releases that pin otherwise
    /// so the panel returns to the user's normal (often external-monitor) screen. Only
    /// meaningful with more than one screen connected — nothing to move on just one.
    /// Called whenever the pick changes and again when the step first appears, so an
    /// untouched system-default choice that happens to resolve to the built-in camera
    /// still moves the panel.
    func applyDisplayPinForCameraSelection() {
        guard NSScreen.screens.count > 1 else { return }
        let isBuiltIn = resolveSelectedCameraDevice()?.deviceType == .builtInWideAngleCamera
        if isBuiltIn {
            guard let builtInScreen = NSScreen.screens.first(where: { $0.isBuiltIn }) else { return }
            GlanceSettings.shared.preferredDisplayID = builtInScreen.stableDisplayID
            GlanceSettings.shared.preferredDisplayName = builtInScreen.localizedName
        } else {
            GlanceSettings.shared.preferredDisplayID = nil
            GlanceSettings.shared.preferredDisplayName = nil
        }
    }

    private func resolveSelectedCameraDevice() -> AVCaptureDevice? {
        if let id = GlanceSettings.shared.defaultCameraID {
            return AVCaptureDevice(uniqueID: id)
        }
        return resolveDefaultCameraDevice()
    }

    /// Same fallback `CameraDeviceCatalog.resolvedDevice()` uses once no override applies.
    private func resolveDefaultCameraDevice() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(for: .video)
    }

    // MARK: - Guided enrollment

    private func observeFrames() {
        withObservationTracking {
            _ = camera.currentFrame
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeFrames()
                await self?.processEnrollFrame()
            }
        }
    }

    private func processEnrollFrame() async {
        guard enrollmentActive, step == .enroll, !enrollmentComplete, !isProcessingFrame,
              let cameraFrame = camera.currentFrame, let pose = currentPose else { return }
        isProcessingFrame = true
        defer { isProcessingFrame = false }
        let generation = enrollmentGeneration
        let processingStartedAt = ContinuousClock.now
        let pipeline = self.pipeline
        let minimumWidth = enrollmentMinimumFaceWidth
        let image = cameraFrame.image
        let outcome = await Task.detached(priority: .userInitiated) {
            do {
                let faces = try FaceDetector.detectFaces(in: image)
                guard let face = FaceRecognitionPipeline.largestFace(in: faces) else {
                    return EnrollFrameOutcome.noFace
                }
                if Float(face.normalizedBoundingBox.width) < minimumWidth {
                    return EnrollFrameOutcome.tooFar
                }
                return EnrollFrameOutcome.ready(try pipeline.recognize(face, in: image))
            } catch FaceRecognitionPipelineError.alignmentFailed {
                return EnrollFrameOutcome.alignmentFailed
            } catch {
                return EnrollFrameOutcome.processingFailed
            }
        }.value

        // Back/Close and a fresh enrollment can run while recognition is suspended.
        guard enrollmentActive, step == .enroll, enrollmentGeneration == generation,
              currentPose == pose else { return }
        guard ContinuousClock.now - processingStartedAt <= EnrollmentCaptureState.maximumFrameGap else {
            _ = enrollmentCapture.consume(.stale, frameID: cameraFrame.id, at: .now)
            return
        }
        let input: EnrollmentFrameInput
        switch outcome {
        case .noFace: input = .noFace
        case .tooFar: input = .tooFar
        case .alignmentFailed: input = .alignmentFailed
        case .processingFailed: input = .processingFailed
        case .ready(let result):
            input = .face(yaw: result.face.yaw, pitch: result.face.pitch,
                          quality: result.quality, alignmentOK: result.alignmentTier == .fivePoint)
        }
        guard let capture = enrollmentCapture.consume(input, frameID: cameraFrame.id, at: .now),
              case .ready(let result) = outcome else { return }
        collectedSamples.append(CollectedSample(
            embedding: result.embedding, pose: capture.pose,
            quality: result.quality, capturedAt: Date()
        ))
        if capture.completesPose {
            if capture.pose == .center {
                centerPulseTick += 1
            } else {
                capturedPoses.insert(capture.pose)
            }
        }
        if enrollmentComplete { await finishEnrollment() }
    }

    /// Runs the camera-complete sequence (instructions fade, preview fades, checkmark
    /// draws) then auto-advances to naming. Samples stay in memory here.
    private func finishEnrollment() async {
        let generation = enrollmentGeneration
        sweepWindow.dismiss()
        try? await Task.sleep(for: .seconds(OnboardingMetrics.guideOverlayFadeOut))
        guard enrollmentActive, step == .enroll, enrollmentGeneration == generation else { return }

        cameraPreviewVisible = false
        try? await Task.sleep(for: .seconds(OnboardingMetrics.previewFadeOut))
        guard enrollmentActive, step == .enroll, enrollmentGeneration == generation else { return }

        try? await Task.sleep(for: .seconds(OnboardingMetrics.checkmarkDelay))
        guard enrollmentActive, step == .enroll, enrollmentGeneration == generation else { return }
        showCheckmark = true

        let elapsed = OnboardingMetrics.guideOverlayFadeOut + OnboardingMetrics.previewFadeOut + OnboardingMetrics.checkmarkDelay
        let remaining = max(OnboardingMetrics.cameraCompleteToNameDelay - elapsed, 0)
        try? await Task.sleep(for: .seconds(remaining))
        guard enrollmentActive, step == .enroll, enrollmentGeneration == generation else { return }

        enrollmentActive = false
        camera.stop()

        navDirection = .forward
        withAnimation(OnboardingMetrics.stepAnimation) { step = .name }
    }

    // MARK: - Naming

    /// Confirms the naming step. In an enrollment-only flow the session is already
    /// unlocked, so this is also the commit point. In the full setup flow nothing can be
    /// written yet — see `finish(password:)`.
    func confirmName() {
        let trimmed = pendingName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            nameError = "Enter a name."
            return
        }
        // Skipped silently in the full setup flow, where the store is still locked and
        // `identities` is unreadable, not empty. `finish(password:)` re-checks once open.
        guard !store.nameIsTaken(trimmed, excluding: enrollmentTarget.identityID) else {
            nameError = "A face named \"\(trimmed)\" is already enrolled."
            return
        }
        nameError = nil

        guard isEnrollmentOnly else {
            navDirection = .forward
            withAnimation(OnboardingMetrics.stepAnimation) { step = .password }
            return
        }

        store.reloadIfUnlocked()
        do {
            try commitEnrollment(name: trimmed)
        } catch {
            // Realistically a session that lapsed between the entry point's Touch ID
            // prompt and now. Stay on this step rather than showing "You're all set"
            // over a save that didn't happen.
            nameError = error.localizedDescription
            return
        }
        navDirection = .forward
        withAnimation(OnboardingMetrics.stepAnimation) { step = .complete }
        scheduleCompletionDismiss()
    }

    /// The single place guided-enrollment samples are persisted. Requires an
    /// unlocked session; in the full setup flow that only exists once
    /// `finish(password:)` has called `SecureCredentialManager.unlockSession`.
    private func commitEnrollment(name: String) throws {
        let samples = collectedSamples.map {
            FaceSample(embedding: $0.embedding, pose: $0.pose.name, capturedAt: $0.capturedAt, quality: $0.quality)
        }
        try store.commitEnrollment(
            replacing: enrollmentTarget.identityID,
            name: name,
            samples: samples,
            embedder: pipeline.embedder
        )
    }

    /// Only a pre-fill for the first-run flow's naming step — never the
    /// stored name, which the user now always chooses themselves.
    static let defaultName: String = {
        let name = NSFullUserName()
        return name.isEmpty ? "Owner" : name
    }()

    // MARK: - Password

    func finish(password: String) async -> Bool {
        // The default Confirm button and the SecureField's Return handler can
        // arrive back-to-back. Keep password replacement and any enrollment
        // commit single-flight even before SwiftUI has redrawn the disabled UI.
        guard !isSavingPassword else { return false }
        let trimmed = password
        guard !trimmed.isEmpty else {
            passwordError = "Enter a password."
            return false
        }
        isSavingPassword = true
        defer { isSavingPassword = false }

        do {
            try await Task.detached(priority: .userInitiated) {
                try SecureCredentialManager.unlockSession(reason: "Set up Glance")
            }.value

            // Only now that the session key exists can samples be encrypted and saved.
            // Empty in the password-only flow, which shares this method.
            store.reloadIfUnlocked()
            if !collectedSamples.isEmpty {
                let name = pendingName.trimmingCharacters(in: .whitespacesAndNewlines)
                // The naming step couldn't run this check while the store was locked.
                guard !store.nameIsTaken(name, excluding: enrollmentTarget.identityID) else {
                    nameError = "A face named \"\(name)\" is already enrolled."
                    navDirection = .backward
                    withAnimation(OnboardingMetrics.stepAnimation) { step = .name }
                    return false
                }
                try commitEnrollment(name: name)
            }

            try await Task.detached(priority: .userInitiated) {
                guard var bytes = trimmed.data(using: .utf8) else {
                    throw SecureCredentialError.emptyPassword
                }
                defer { bytes.resetBytes(in: 0..<bytes.count) }
                try SecureCredentialManager.savePassword(bytes)
            }.value
            passwordError = nil
            navDirection = .forward
            withAnimation(OnboardingMetrics.stepAnimation) { step = .complete }
            scheduleCompletionDismiss()
            return true
        } catch {
            passwordError = error.localizedDescription
            return false
        }
    }

    /// The "You're all set" screen has no controls — it dismisses itself, then hands off
    /// to `onFirstRunComplete` once the notch is gone, for first-run and the post-update
    /// notice alike.
    private func scheduleCompletionDismiss() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(OnboardingMetrics.completeScreenDismissDelay))
            guard let self else { return }
            let shouldFireCompletion = self.isFirstRunFlow || self.isPostUpdateNotice
            let onComplete = self.onFirstRunComplete
            self.teardown()
            NotchOverlayController.shared.dismissOnboarding()
            if shouldFireCompletion {
                onComplete?()
            }
        }
    }
}
