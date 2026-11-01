import Foundation

struct RecordingCallbackCoordinator {
    enum FinishDisposition: Equatable {
        case transcribe
        case discard
        case stale
    }

    enum ErrorDisposition: Equatable {
        case present
        case cancelled
        case stale
    }

    private(set) var activeRecordingID: UUID?
    private var stoppedRecordingID: UUID?
    private var cancelledFinishID: UUID?

    mutating func beginRecording(_ recordingID: UUID) -> Bool {
        guard activeRecordingID == nil else { return false }
        activeRecordingID = recordingID
        stoppedRecordingID = nil
        cancelledFinishID = nil
        return true
    }

    func acceptsMeter(for recordingID: UUID) -> Bool {
        activeRecordingID == recordingID && stoppedRecordingID != recordingID
    }

    mutating func stopRecording(_ recordingID: UUID) -> Bool {
        guard activeRecordingID == recordingID else { return false }
        stoppedRecordingID = recordingID
        return true
    }

    mutating func cancelPendingFinish(_ recordingID: UUID) -> Bool {
        guard activeRecordingID == recordingID,
              stoppedRecordingID == recordingID else {
            return false
        }
        cancelledFinishID = recordingID
        return true
    }

    mutating func finishRecording(_ recordingID: UUID) -> FinishDisposition {
        guard activeRecordingID == recordingID,
              stoppedRecordingID == recordingID else {
            return .stale
        }

        let shouldDiscard = cancelledFinishID == recordingID
        clearActiveRecording()
        return shouldDiscard ? .discard : .transcribe
    }

    mutating func failRecording(_ recordingID: UUID) -> ErrorDisposition {
        guard activeRecordingID == recordingID else { return .stale }

        let wasCancelled = cancelledFinishID == recordingID
        clearActiveRecording()
        return wasCancelled ? .cancelled : .present
    }

    mutating func abandonRecording(_ recordingID: UUID) {
        guard activeRecordingID == recordingID else { return }
        clearActiveRecording()
    }

    private mutating func clearActiveRecording() {
        activeRecordingID = nil
        stoppedRecordingID = nil
        cancelledFinishID = nil
    }
}
