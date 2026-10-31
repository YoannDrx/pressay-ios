import Foundation
import Testing
@testable import PressayCore

@Suite struct SetupGuideTests {
    @Test func startsWithTheMicrophone() {
        let evidence = SetupEvidence()
        #expect(evidence.firstPending == .microphone)
        #expect(evidence.doneCount == 0)
        #expect(!evidence.isReadyToDictate)
    }

    @Test func theFullAccessMarkProvesTheKeyboardIsAdded() {
        let evidence = SetupEvidence(microphoneGranted: true, fullAccessSeen: true)
        #expect(evidence.isDone(.keyboard))
        #expect(evidence.isDone(.fullAccess))
        #expect(evidence.isReadyToDictate)
        #expect(evidence.firstPending == .trigger)
    }

    @Test func anAddedKeyboardStillNeedsFullAccess() {
        let evidence = SetupEvidence(microphoneGranted: true, keyboardAdded: true)
        #expect(evidence.firstPending == .fullAccess)
        #expect(!evidence.isReadyToDictate)
    }

    @Test func theTriggerCanBeSkipped() {
        var evidence = SetupEvidence(microphoneGranted: true, keyboardAdded: true, fullAccessSeen: true)
        #expect(evidence.firstPending == .trigger)
        evidence.triggerSkipped = true
        #expect(evidence.firstPending == .firstDictation)
        evidence.insertionSeen = true
        #expect(evidence.isComplete)
        #expect(evidence.doneCount == SetupStep.allCases.count)
    }

    @Test func resumesWhereTheUserLeftUnlessItIsDone() {
        let evidence = SetupEvidence(microphoneGranted: true)
        #expect(SetupResume.step(saved: .fullAccess, evidence: evidence) == .fullAccess)
        #expect(SetupResume.step(saved: .microphone, evidence: evidence) == .keyboard)
        #expect(SetupResume.step(saved: nil, evidence: evidence) == .keyboard)
        let complete = SetupEvidence(
            microphoneGranted: true, keyboardAdded: true, fullAccessSeen: true, triggerUsed: true, insertionSeen: true
        )
        #expect(SetupResume.step(saved: .trigger, evidence: complete) == nil)
    }

    @Test(arguments: [
        ("iPhone15,4", false), // iPhone 15
        ("iPhone16,1", true), // iPhone 15 Pro
        ("iPhone16,2", true), // iPhone 15 Pro Max
        ("iPhone17,5", true), // iPhone 16e
        ("iPhone18,3", true), // iPhone 17
        ("iPhone14,7", false), // iPhone 14
        ("iPad16,3", false),
        ("x86_64", false),
    ])
    func knowsWhichIPhonesHaveAnActionButton(model: String, expected: Bool) {
        #expect(ActionButtonSupport.isAvailable(modelIdentifier: model) == expected)
    }
}
