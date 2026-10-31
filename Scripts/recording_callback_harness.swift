import Foundation

@main
struct RecordingCallbackHarness {
    static func main() {
        var callbacks = RecordingCallbackCoordinator()
        let firstRecording = UUID()
        let nextRecording = UUID()

        precondition(callbacks.beginRecording(firstRecording))
        precondition(callbacks.stopRecording(firstRecording))
        precondition(callbacks.cancelPendingFinish(firstRecording))
        precondition(callbacks.finishRecording(firstRecording) == .discard)

        precondition(callbacks.beginRecording(nextRecording))
        precondition(callbacks.acceptsMeter(for: nextRecording))
        precondition(!callbacks.acceptsMeter(for: firstRecording))
        precondition(callbacks.finishRecording(firstRecording) == .stale)
        precondition(callbacks.failRecording(firstRecording) == .stale)
        precondition(callbacks.stopRecording(nextRecording))
        precondition(!callbacks.acceptsMeter(for: nextRecording))
        precondition(callbacks.finishRecording(nextRecording) == .transcribe)
        precondition(callbacks.failRecording(nextRecording) == .stale)

        let cancelledErrorRecording = UUID()
        precondition(callbacks.beginRecording(cancelledErrorRecording))
        precondition(callbacks.stopRecording(cancelledErrorRecording))
        precondition(callbacks.cancelPendingFinish(cancelledErrorRecording))
        precondition(callbacks.failRecording(cancelledErrorRecording) == .cancelled)
        precondition(callbacks.failRecording(cancelledErrorRecording) == .stale)

        print("recording callback lifecycle passed")
    }
}
