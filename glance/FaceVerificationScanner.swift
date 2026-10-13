//
//  FaceVerificationScanner.swift
//  glance
//
//  One camera/recognition owner shared by callers. Verification never reads or
//  types a password; the caller decides what a verified face may authorize.
//

import Foundation
import CoreGraphics

@MainActor
final class FaceVerificationScanner {
    struct Verification {
        let match: ScoredIdentity
        let livenessNote: String
    }

    enum Outcome {
        case verified(Verification)
        case consistentlyWrongFace
        case spoofSuspected(reason: String?)
        case unavailable(message: String)
        case noResolution
        case cancelled
    }

    let camera = CameraManager()
    let pipeline = FaceRecognitionPipeline()
    private(set) var activeRequestID: UUID?
    private var generation: UInt64 = 0
    private let wrongFaceGraceDuration: Duration = .seconds(2)

    /// Cancelling one caller must never stop a newer caller's camera.
    func cancel(requestID: UUID) {
        guard activeRequestID == requestID else { return }
        generation &+= 1
        activeRequestID = nil
        camera.stop()
    }

    /// Starts a fresh recognition/liveness window. A newer request supersedes the
    /// previous one, but only the current request may stop the shared camera.
    /// `timeout` starts after camera setup, as it does in the lock-screen flow.
    /// `shouldContinue` must remain true for the caller's original request.
    func scan(
        requestID: UUID,
        timeout: TimeInterval,
        thresholdProvider: @escaping @MainActor () -> Float,
        shouldContinue: @escaping @MainActor () -> Bool,
        onStarted: @MainActor () -> Void = {}
    ) async -> Outcome {
        guard !Task.isCancelled, shouldContinue() else { return .cancelled }
        generation &+= 1
        let scanGeneration = generation
        activeRequestID = requestID

        func isCurrent() -> Bool {
            activeRequestID == requestID && generation == scanGeneration
        }
        func mayContinue() -> Bool {
            isCurrent() && !Task.isCancelled && shouldContinue()
        }
        defer {
            if isCurrent() {
                activeRequestID = nil
                camera.stop()
            }
        }

        await camera.start()
        guard mayContinue() else {
            // Permission approval may let start() resume after cancellation. If
            // nobody replaced this request, stop that late camera start as well.
            if activeRequestID == nil { camera.stop() }
            return .cancelled
        }
        if let error = camera.errorMessage { return .unavailable(message: error) }

        onStarted()
        guard mayContinue() else { return .cancelled }
        let deadline = Date().addingTimeInterval(timeout)
        let livenessEnabled = GlanceSettings.shared.livenessChecksEnabled
        let liveness = LivenessAnalyzer()
        liveness.modeProvider = { GlanceSettings.shared.livenessMode }
        var wrongFaceStartedAt: ContinuousClock.Instant?
        var readyMatch: ScoredIdentity?
        var livenessConfirmed = !livenessEnabled
        var lastFaceBoundingBox: CGRect?
        var lastProcessedFrameID: UInt64?

        while Date() < deadline {
            guard mayContinue() else { return .cancelled }
            guard let frame = camera.currentFrame, frame.id != lastProcessedFrameID else {
                do { try await Task.sleep(for: .milliseconds(20)) }
                catch { return .cancelled }
                guard mayContinue() else { return .cancelled }
                continue
            }
            lastProcessedFrameID = frame.id

            let pipeline = self.pipeline
            let previousBoundingBox = lastFaceBoundingBox
            let outcome = await Task.detached(priority: .userInitiated) { () -> (FaceRecognitionResult, LivenessFrame)? in
                guard let result = try? pipeline.recognize(in: frame.image, preferNear: previousBoundingBox) else { return nil }
                let faceCrop = CameraManager.renderCrop(from: frame, imageRect: result.face.boundingBox)
                return (result, LivenessFeatureExtractor.extract(from: result, frame: frame.image, faceCrop: faceCrop))
            }.value
            guard mayContinue() else { return .cancelled }
            guard Date() < deadline else { return .noResolution }

            guard let (result, livenessFrame) = outcome else {
                wrongFaceStartedAt = nil
                lastFaceBoundingBox = nil
                do { try await Task.sleep(for: .milliseconds(20)) }
                catch { return .cancelled }
                guard mayContinue() else { return .cancelled }
                continue
            }
            lastFaceBoundingBox = result.face.normalizedBoundingBox

            // Liveness is fed independently of the identity match. All existing
            // cues and tuning remain enabled, and a deny overrides confirmation.
            var confirmingCue: LivenessCue?
            if livenessEnabled {
                let snapshot = liveness.observe(livenessFrame)
                switch snapshot.decision {
                case .denied:
                    return .spoofSuspected(reason: snapshot.decision.denialReason)
                case .confirmed(let cue):
                    livenessConfirmed = true
                    confirmingCue = cue
                case .pending:
                    break
                }
            }

            let scored = pipeline.score(result.embedding, against: FaceEnrollmentStore.shared.activeIdentities)
            let matched = pipeline.bestMatch(in: scored, threshold: thresholdProvider())
            if let matched {
                wrongFaceStartedAt = nil
                readyMatch = matched
            } else {
                readyMatch = nil
                if wrongFaceStartedAt == nil { wrongFaceStartedAt = .now }
                if let wrongFaceStartedAt,
                   ContinuousClock.now - wrongFaceStartedAt >= wrongFaceGraceDuration {
                    return .consistentlyWrongFace
                }
            }

            if let readyMatch, livenessConfirmed {
                let livenessNote = livenessEnabled
                    ? (confirmingCue.map { "live via \($0.title)" } ?? "liveness clear")
                    : "liveness off"
                return .verified(Verification(match: readyMatch, livenessNote: livenessNote))
            }

            do { try await Task.sleep(for: .milliseconds(20)) }
            catch { return .cancelled }
            guard mayContinue() else { return .cancelled }
        }
        return .noResolution
    }
}
