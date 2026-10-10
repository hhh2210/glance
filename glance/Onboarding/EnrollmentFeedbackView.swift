import SwiftUI

/// Shared by the live camera view and the camera-free preview tool.
struct EnrollmentFeedbackView: View {
    let phase: EnrollmentCaptureState.Phase
    let pose: EnrollmentPose?
    let completedDirections: Int
    let capturedSamples: Int

    var body: some View {
        VStack(spacing: 4) {
            Text(instruction)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(2)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(2)
            if phase != .complete {
                Text("\(completedDirections) of 9 directions · \(capturedSamples) of 2 captures",
                     comment: "Enrollment progress: completed directions, then samples saved for the current direction.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private var instruction: LocalizedStringResource {
        switch phase {
        case .complete: return "Face captured"
        case .holding: return "Hold still"
        case .capturing: return "Capturing — keep still"
        case .blocked(let blocker):
            switch blocker {
            case .waitingForCamera: return "Waiting for the camera"
            case .noFace: return "Bring your face into view"
            case .tooFar: return "Bring your face closer"
            case .missingPose: return "Face angle unavailable"
            case .alignment: return "Keep your whole face visible"
            case .quality: return "Face image isn't clear enough"
            case .processingFailed: return "Couldn't capture your face"
            case .warmingUp: return "Getting ready — keep still"
            case .excessiveTurn: return "Turn back a little toward the camera"
            case .adjustPose: return pose?.instruction ?? "Look toward the camera"
            case .adjustYaw(.left): return "Turn your head a little left"
            case .adjustYaw(.right): return "Turn your head a little right"
            case .adjustYaw(.none): return "Face the camera without turning sideways"
            case .adjustPitch(.up): return "Lift your chin a little"
            case .adjustPitch(.down): return "Lower your chin a little"
            case .adjustPitch(.none): return "Level your chin"
            }
        }
    }

    private var detail: LocalizedStringResource {
        switch phase {
        case .complete: return "All directions captured"
        case .holding: return "Keep this position until capture finishes"
        case .capturing: return "Wait for the next direction"
        case .blocked(let blocker):
            switch blocker {
            case .adjustPitch:
                switch pose?.yawBand {
                case .left: return "Your left turn is enough"
                case .right: return "Your right turn is enough"
                default: return "Keep facing the camera"
                }
            case .adjustYaw: return "Keep your chin at this height"
            case .missingPose: return "Look toward the camera, then try a small turn"
            case .alignment: return "Couldn't capture enough face detail"
            case .quality: return "Keep your face visible and steady"
            case .processingFailed: return "Please try again with your face in view"
            case .waitingForCamera, .warmingUp: return "Capture will start when ready"
            default: return "Turn your head, then hold still"
            }
        }
    }

}

/// Progress is supplied by accepted camera frames; this view never runs a timer.
/// A full ring means the hold finished, not that the samples were captured.
struct EnrollmentHoldRing: View {
    let progress: Double
    let isCapturing: Bool
    let diameter: CGFloat
    let tint: Color

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.2), lineWidth: 3)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hold progress")
        .accessibilityValue(isCapturing ? Text("Hold complete. Capturing.") : Text(progress, format: .percent))
    }
}
