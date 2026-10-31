import PressayShared
import Testing
@testable import PressayCore

@Suite struct DictationStateMachineTests {
    @Test func toggleStartsThenStops() {
        var machine = DictationStateMachine()
        #expect(machine.handle(.toggle) == .startCapture)
        #expect(machine.phase == .recording)
        #expect(machine.handle(.toggle) == .stopCapture(.toggle))
        #expect(machine.phase == .transcribing)
        #expect(machine.handle(.delivered) == nil)
        #expect(machine.phase == .delivered)
    }

    @Test func toggleIsIgnoredWhileTranscribing() {
        var machine = DictationStateMachine(phase: .transcribing)
        #expect(machine.handle(.toggle) == nil)
        #expect(machine.phase == .transcribing)
    }

    /// A late tap on the Live Activity's Stop button must never start a new recording.
    @Test func stopOutsideARecordingDoesNothing() {
        for phase in [DictationPhase.idle, .transcribing, .delivered, .failed] {
            var machine = DictationStateMachine(phase: phase)
            #expect(machine.handle(.stop(.stopButton)) == nil)
            #expect(machine.phase == phase)
        }
    }

    @Test func everyStopReasonEndsARecording() {
        for reason in StopReason.allCases {
            var machine = DictationStateMachine(phase: .recording)
            #expect(machine.handle(.stop(reason)) == .stopCapture(reason))
            #expect(machine.phase == .transcribing)
        }
    }

    @Test func aNewDictationStartsAfterDeliveryOrFailure() {
        for phase in [DictationPhase.delivered, .failed] {
            var machine = DictationStateMachine(phase: phase)
            #expect(machine.handle(.toggle) == .startCapture)
            #expect(machine.phase == .recording)
        }
    }

    @Test func captureFailureEndsTheRecording() {
        var machine = DictationStateMachine(phase: .recording)
        machine.handle(.captureFailed)
        #expect(machine.phase == .failed)
    }

    @Test func transcriptionFailureIsReported() {
        var machine = DictationStateMachine(phase: .transcribing)
        machine.handle(.failed)
        #expect(machine.phase == .failed)
    }

    @Test func resultsOutsideTranscriptionAreIgnored() {
        var machine = DictationStateMachine(phase: .recording)
        #expect(machine.handle(.delivered) == nil)
        #expect(machine.phase == .recording)
    }
}
