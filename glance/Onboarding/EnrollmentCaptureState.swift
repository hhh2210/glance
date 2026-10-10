import Foundation

/// A single guided head pose captured during enrollment — center plus the
/// 8 compass directions, in the exact order presented to the user.
nonisolated enum EnrollmentPose: Int, CaseIterable, Sendable {
    case center, left, topLeft, top, topRight, right, bottomRight, bottom, bottomLeft

    enum YawBand { case left, none, right }
    enum PitchBand { case up, none, down }

    var yawBand: YawBand {
        switch self {
        case .left, .topLeft, .bottomLeft: return .left
        case .right, .topRight, .bottomRight: return .right
        case .center, .top, .bottom: return .none
        }
    }

    var pitchBand: PitchBand {
        switch self {
        case .top, .topLeft, .topRight: return .up
        case .bottom, .bottomLeft, .bottomRight: return .down
        case .center, .left, .right: return .none
        }
    }

    /// Compass angle (0 = up, clockwise) this pose's ring sector is centered
    /// on. `nil` for center, which pulses the whole ring instead of
    /// claiming a sector.
    var compassAngle: Double? {
        switch self {
        case .center: return nil
        case .left: return 270
        case .topLeft: return 315
        case .top: return 0
        case .topRight: return 45
        case .right: return 90
        case .bottomRight: return 135
        case .bottom: return 180
        case .bottomLeft: return 225
        }
    }

    var instruction: LocalizedStringResource {
        switch self {
        case .center: return "Look straight at the camera"
        case .left: return "Turn your head slightly left"
        case .topLeft: return "Turn slightly left and lift your chin"
        case .top: return "Turn your head slightly up"
        case .topRight: return "Turn slightly right and lift your chin"
        case .right: return "Turn your head slightly right"
        case .bottomRight: return "Turn slightly right and lower your chin"
        case .bottom: return "Turn your head slightly down"
        case .bottomLeft: return "Turn slightly left and lower your chin"
        }
    }

    /// Relaxes this pose's yaw/pitch bands — same knob as `stallWidenFactor`, so >1 is easier.
    var matchLeniency: Float {
        switch self {
        case .bottomLeft, .bottomRight: return 1.5
        case .bottom: return 1.2
        default: return 1
        }
    }

    /// Persisted alongside each sample so a saved identity records which
    /// pose each embedding came from.
    var name: String {
        switch self {
        case .center: return "center"
        case .left: return "left"
        case .topLeft: return "top_left"
        case .top: return "top"
        case .topRight: return "top_right"
        case .right: return "right"
        case .bottomRight: return "bottom_right"
        case .bottom: return "bottom"
        case .bottomLeft: return "bottom_left"
        }
    }
}

/// The same result controls capture and its on-screen explanation. A direction alone
/// never implies readiness: size, pose, alignment and quality must all pass.
nonisolated enum EnrollmentBlocker: Equatable {
    case waitingForCamera, noFace, tooFar, missingPose, alignment, quality, processingFailed, warmingUp
    case excessiveTurn, adjustPose
    case adjustYaw(EnrollmentPose.YawBand)
    case adjustPitch(EnrollmentPose.PitchBand)
}

nonisolated enum EnrollmentFrameInput {
    case noFace, tooFar, alignmentFailed, processingFailed, stale
    case face(yaw: Float?, pitch: Float?, quality: Float?, alignmentOK: Bool)
}

/// Camera-free enrollment policy and sample advancement, exercised by the offline
/// self-test. Times and frame IDs are supplied by the caller, not by a UI animation.
nonisolated struct EnrollmentCaptureState: Equatable {
    static let samplesPerPose = 2
    static let requiredMatchStreak = 3
    static let holdDuration: Duration = .milliseconds(500)
    static let initialCaptureDelay: Duration = .seconds(1.5)
    static let stallTimeout: Duration = .seconds(12)
    /// Tolerate processing jitter, but never carry a hold across a camera stall.
    /// Kept separate from the hold duration so this tolerance can be tuned explicitly.
    static let maximumFrameGap: Duration = .seconds(1)

    enum Phase: Equatable {
        case blocked(EnrollmentBlocker)
        case holding
        case capturing
        case complete
    }

    struct Capture: Equatable {
        let pose: EnrollmentPose
        let completesPose: Bool
    }

    private(set) var poseIndex = 0
    private(set) var samplesForPose = 0
    private(set) var phase: Phase = .blocked(.waitingForCamera)
    private(set) var holdProgress = 0.0
    private var matchStreak = 0
    private var holdStartedAt: ContinuousClock.Instant?
    private var lastFrameAt: ContinuousClock.Instant?
    private var lastFrameID: UInt64?
    private var poseStartedAt: ContinuousClock.Instant
    private let captureReadyAt: ContinuousClock.Instant

    init(startedAt: ContinuousClock.Instant = .now) {
        poseStartedAt = startedAt
        captureReadyAt = startedAt + Self.initialCaptureDelay
    }

    var currentPose: EnrollmentPose? { EnrollmentPose(rawValue: poseIndex) }
    var totalSamples: Int { poseIndex * Self.samplesPerPose + samplesForPose }

    /// Returns a capture only when a new frame completes the real hold/streak rules.
    /// A rejected frame resets the hold and streak, but preserves accepted samples.
    mutating func consume(_ input: EnrollmentFrameInput, frameID: UInt64, at now: ContinuousClock.Instant) -> Capture? {
        guard let pose = currentPose, lastFrameID.map({ frameID > $0 }) ?? true else { return nil }
        lastFrameID = frameID
        if let lastFrameAt, now - lastFrameAt > Self.maximumFrameGap {
            interrupt(with: .waitingForCamera)
        }
        lastFrameAt = now

        if let blocker = Self.blocker(for: input, pose: pose, widened: now - poseStartedAt > Self.stallTimeout) {
            interrupt(with: blocker)
            return nil
        }
        guard now >= captureReadyAt else {
            interrupt(with: .warmingUp)
            return nil
        }

        if holdStartedAt == nil { holdStartedAt = now }
        let elapsed = now - (holdStartedAt ?? now)
        holdProgress = min(1, Double(elapsed / Self.holdDuration))
        guard elapsed >= Self.holdDuration else {
            phase = .holding
            return nil
        }

        phase = .capturing
        matchStreak += 1
        guard matchStreak >= Self.requiredMatchStreak else { return nil }
        matchStreak = 0
        samplesForPose += 1
        let completesPose = samplesForPose == Self.samplesPerPose
        if completesPose {
            poseIndex += 1
            samplesForPose = 0
            poseStartedAt = now
            interrupt(with: .adjustPose)
            if currentPose == nil { phase = .complete }
        }
        return Capture(pose: pose, completesPose: completesPose)
    }

    private mutating func interrupt(with blocker: EnrollmentBlocker) {
        holdStartedAt = nil
        holdProgress = 0
        matchStreak = 0
        phase = .blocked(blocker)
    }

    static func blocker(for input: EnrollmentFrameInput, pose: EnrollmentPose, widened: Bool) -> EnrollmentBlocker? {
        switch input {
        case .stale: return .waitingForCamera
        case .noFace: return .noFace
        case .tooFar: return .tooFar
        case .alignmentFailed: return .alignment
        case .processingFailed: return .processingFailed
        case .face(let yaw, let pitch, let quality, let alignmentOK):
            guard let yaw, let pitch, yaw.isFinite, pitch.isFinite else { return .missingPose }
            // Preserve the existing enrollment envelope, including its strict edges.
            guard abs(yaw) < 0.51, abs(pitch) < 0.37 else { return .excessiveTurn }
            guard alignmentOK else { return .alignment }
            // Preserve the existing floor and nil-quality behavior. Do not infer a
            // lighting or blur diagnosis from Vision's aggregate quality score.
            if let quality, !quality.isFinite || quality < 0.2 { return .quality }

            let factor: Float = (widened ? 1.25 : 1) * pose.matchLeniency
            let yawOK: Bool
            switch pose.yawBand {
            case .none: yawOK = abs(yaw) < 0.18 * factor
            case .left: yawOK = yaw > 0.24 / factor
            case .right: yawOK = yaw < -0.24 / factor
            }
            let pitchOK: Bool
            switch pose.pitchBand {
            case .none: pitchOK = abs(pitch) < 0.15 * factor
            case .up: pitchOK = pitch < -0.17 / factor
            case .down: pitchOK = pitch > 0.17 / factor
            }
            switch (yawOK, pitchOK) {
            case (false, false): return .adjustPose
            case (false, true): return .adjustYaw(pose.yawBand)
            case (true, false): return .adjustPitch(pose.pitchBand)
            case (true, true): return nil
            }
        }
    }
}
