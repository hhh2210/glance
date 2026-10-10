// Offline tests compile the production state machine, with no camera or app state.
// Run: tools/enrollment_selftest.sh
import Foundation

@main
@MainActor
enum EnrollmentSelfTest {
    static var checks = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
        checks += 1
        guard condition() else { fatalError("Line \(line): \(message)") }
    }

    nonisolated static func face(_ yaw: Float = 0, _ pitch: Float = 0, quality: Float? = 0.8, aligned: Bool = true) -> EnrollmentFrameInput {
        .face(yaw: yaw, pitch: pitch, quality: quality, alignmentOK: aligned)
    }

    static func blocker(_ input: EnrollmentFrameInput, _ pose: EnrollmentPose = .topLeft, widened: Bool = false) -> EnrollmentBlocker? {
        EnrollmentCaptureState.blocker(for: input, pose: pose, widened: widened)
    }

    static func main() {
        testReadiness()
        testHoldAndInterruption()
        testFreshnessAndStall()
        testAllDirections()
        print("Enrollment self-test: \(checks) checks passed (production evaluator and capture state).")
    }

    static func testReadiness() {
        // Both axes at 80% used to saturate the direction indicator via hypot.
        expect(blocker(face(0.192, -0.136)) == .adjustPose, "80% diagonal must not be ready")
        expect(blocker(face(0.3, -0.136)) == .adjustPitch(.up), "only pitch is missing")
        expect(blocker(face(0.192, -0.22)) == .adjustYaw(.left), "only yaw is missing")
        expect(blocker(face(0.3, -0.22)) == nil, "both axes pass")
        expect(blocker(face(-0.3, 0.22), .bottomRight) == nil, "opposite diagonal signs")
        expect(blocker(face(0.3, 0), .topLeft) == .adjustPitch(.up), "up has negative pitch")
        expect(blocker(face(0, -0.22), .top) == nil, "top accepts centered yaw")
        expect(blocker(face(0.19, -0.22), .top) == .adjustYaw(.none), "top also needs centered yaw")
        expect(blocker(face(0.3, 0.16), .left) == .adjustPitch(.none), "left also needs level pitch")

        expect(blocker(face(0.24, -0.22)) == .adjustYaw(.left), "yaw inner edge is strict")
        expect(blocker(face(0.3, -0.17)) == .adjustPitch(.up), "pitch inner edge is strict")
        expect(blocker(face(0.51, -0.22)) == .excessiveTurn, "yaw outer edge is strict")
        expect(blocker(face(0.3, -0.37)) == .excessiveTurn, "pitch outer edge is strict")
        expect(blocker(face(-0.51, 0.2), .bottomRight) == .excessiveTurn, "negative yaw outer edge")
        expect(blocker(face(0.3, 0.37), .bottomLeft) == .excessiveTurn, "positive pitch outer edge")
        expect(blocker(face(0.18, 0), .center) == .adjustYaw(.none), "center yaw edge is strict")
        expect(blocker(face(0, 0.15), .center) == .adjustPitch(.none), "center pitch edge is strict")
        expect(blocker(face(0.2, -0.145), widened: false) == .adjustPose, "narrow bands reject")
        expect(blocker(face(0.2, -0.145), widened: true) == nil, "stall widens both bands")
        expect(blocker(face(0.51, -0.22), widened: true) == .excessiveTurn, "stall does not relax outer cap")
        expect(blocker(face(0.17, 0.12), .bottomLeft) == nil, "bottom diagonal keeps 1.5 leniency")
        expect(blocker(face(0, 0.145), .bottom) == nil, "bottom keeps 1.2 leniency")

        expect(blocker(.noFace) == .noFace, "no face is explicit")
        expect(blocker(.tooFar) == .tooFar, "distance is explicit")
        expect(blocker(.alignmentFailed) == .alignment, "alignment error is not no face")
        expect(blocker(.processingFailed) == .processingFailed, "processing errors remain distinct")
        expect(blocker(.stale) == .waitingForCamera, "stale input cannot capture")
        expect(blocker(.face(yaw: nil, pitch: -0.22, quality: 0.8, alignmentOK: true)) == .missingPose, "missing pose")
        expect(blocker(face(.nan, -0.22)) == .missingPose, "NaN yaw")
        expect(blocker(face(0.3, .infinity)) == .missingPose, "infinite pitch")
        expect(blocker(face(0.3, -0.22, aligned: false)) == .alignment, "five-point alignment required")
        expect(blocker(face(0.3, -0.22, quality: 0.199)) == .quality, "existing quality floor")
        expect(blocker(face(0.3, -0.22, quality: 0.2)) == nil, "quality edge is inclusive")
        expect(blocker(face(0.3, -0.22, quality: nil)) == nil, "missing quality remains accepted")
        expect(blocker(face(0.3, -0.22, quality: .nan)) == .quality, "NaN quality")
        expect(blocker(face(0.3, -0.22, quality: .infinity)) == .quality, "infinite quality")
    }

    static func testHoldAndInterruption() {
        let origin = ContinuousClock.now
        var state = EnrollmentCaptureState(startedAt: origin)
        var id: UInt64 = 0
        func feed(_ milliseconds: Int, _ input: EnrollmentFrameInput = face()) -> EnrollmentCaptureState.Capture? {
            id += 1
            return state.consume(input, frameID: id, at: origin + .milliseconds(milliseconds))
        }

        expect(feed(1000) == nil && state.phase == .blocked(.warmingUp), "initial 1.5s warmup")
        expect(feed(1500) == nil && state.phase == .holding && state.holdProgress == 0, "start hold")
        expect(feed(1750) == nil && state.holdProgress == 0.5, "real half-hold progress")
        expect(feed(1999) == nil && state.phase == .holding, "499ms does not start sampling")
        expect(feed(2000) == nil && state.phase == .capturing, "500ms starts sampling, not completion")
        expect(state.holdProgress == 1 && state.totalSamples == 0, "full hold ring is not a sample")
        expect(feed(2030) == nil, "two matching frames insufficient")
        expect(feed(2060) == .init(pose: .center, completesPose: false), "third frame captures first sample")
        expect(state.samplesForPose == 1 && state.phase == .capturing, "keep holding for second sample")

        expect(feed(2080, face(quality: 0.1)) == nil, "quality loss interrupts")
        expect(state.phase == .blocked(.quality) && state.holdProgress == 0, "failure clears hold")
        expect(state.samplesForPose == 1 && state.totalSamples == 1, "accepted first sample survives")
        expect(feed(2100) == nil && state.phase == .holding, "reacquisition restarts hold")
        expect(feed(2599) == nil && state.phase == .holding, "replacement hold needs all 500ms")
        expect(feed(2600) == nil && state.phase == .capturing, "first resumed sampling frame")
        expect(feed(2630) == nil, "second resumed frame")
        expect(feed(2660) == .init(pose: .center, completesPose: true), "third resumed frame finishes pose")
        expect(state.totalSamples == 2 && state.currentPose == .left, "advance exactly one pose")
        expect(state.holdProgress == 0 && state.samplesForPose == 0, "next pose resets only local progress")
        expect(feed(2700, face(0.3)) == nil && state.phase == .holding, "no repeated startup delay")

        // Every blocker follows the same reset path, including an invalid frame in a streak.
        for input in [EnrollmentFrameInput.noFace, .tooFar, .alignmentFailed, .processingFailed, .stale,
                      face(0.8), face(0.3, 0.2), face(0.3, quality: 0.1), face(.nan)] {
            var probe = EnrollmentCaptureState(startedAt: origin)
            _ = probe.consume(face(), frameID: 1, at: origin + .milliseconds(1500))
            _ = probe.consume(face(), frameID: 2, at: origin + .milliseconds(2000))
            _ = probe.consume(face(), frameID: 3, at: origin + .milliseconds(2030))
            _ = probe.consume(input, frameID: 4, at: origin + .milliseconds(2040))
            expect(probe.holdProgress == 0 && probe.totalSamples == 0, "blocker clears in-flight streak")
            expect(probe.consume(face(), frameID: 5, at: origin + .milliseconds(2050)) == nil,
                   "a previous two-frame streak cannot leak across a blocker")
        }
    }

    static func testFreshnessAndStall() {
        let origin = ContinuousClock.now
        var state = EnrollmentCaptureState(startedAt: origin)
        _ = state.consume(face(), frameID: 10, at: origin + .milliseconds(1500))
        expect(state.consume(face(), frameID: 10, at: origin + .milliseconds(2000)) == nil,
               "duplicate frame does not count")
        expect(state.phase == .holding && state.holdProgress == 0, "duplicate cannot advance displayed hold")
        expect(state.consume(face(), frameID: 9, at: origin + .milliseconds(2100)) == nil,
               "older frame cannot count")
        _ = state.consume(face(), frameID: 11, at: origin + .milliseconds(2601))
        expect(state.phase == .holding && state.holdProgress == 0, "long frame gap restarts hold")
        _ = state.consume(face(), frameID: 12, at: origin + .milliseconds(2851))
        expect(state.holdProgress == 0.5, "fresh frames resume actual hold")

        var stalled = EnrollmentCaptureState(startedAt: origin)
        _ = stalled.consume(face(0.2), frameID: 1, at: origin + .seconds(12))
        expect(stalled.phase == .blocked(.adjustYaw(.none)), "stall widening is strictly after 12s")
        _ = stalled.consume(face(0.2), frameID: 2, at: origin + .milliseconds(12001))
        expect(stalled.phase == .holding, "production state applies widened bands after 12s")
        _ = stalled.consume(face(0.51), frameID: 3, at: origin + .milliseconds(12002))
        expect(stalled.phase == .blocked(.excessiveTurn), "widening never accepts outer cap")
    }

    static func testAllDirections() {
        let origin = ContinuousClock.now
        var state = EnrollmentCaptureState(startedAt: origin)
        var id: UInt64 = 0
        var start = 1500
        var samples: [EnrollmentPose] = []
        for pose in EnrollmentPose.allCases {
            let yaw: Float = switch pose.yawBand { case .left: 0.3; case .right: -0.3; case .none: 0 }
            let pitch: Float = switch pose.pitchBand { case .up: -0.22; case .down: 0.22; case .none: 0 }
            expect(state.currentPose == pose, "original nine-pose order")
            for offset in [0, 250, 500, 530, 560, 590, 620, 650] {
                id += 1
                if let capture = state.consume(face(yaw, pitch), frameID: id, at: origin + .milliseconds(start + offset)) {
                    samples.append(capture.pose)
                    expect(capture.completesPose == (offset == 650), "only second sample completes pose")
                }
            }
            expect(samples.filter { $0 == pose }.count == 2, "exactly two samples without a second hold")
            start += 700
        }
        expect(state.phase == .complete && state.currentPose == nil, "all directions complete")
        expect(state.totalSamples == 18 && samples.count == 18, "unchanged total of 18 samples")
        expect(state.consume(face(), frameID: id + 1, at: origin + .seconds(20)) == nil,
               "completed state cannot capture extra samples")
    }
}
