import Testing
@testable import leanring_buddy

struct DoModeTests {
    @Test func confirmationClassifierRecognizesYes() {
        #expect(SpokenConfirmationAnswer.classify("yes go ahead") == .yes)
        #expect(SpokenConfirmationAnswer.classify("Yeah, do it") == .yes)
    }

    @Test func confirmationClassifierTreatsNegativesAsNoEvenWithYes() {
        #expect(SpokenConfirmationAnswer.classify("no") == .no)
        #expect(SpokenConfirmationAnswer.classify("yes wait") == .no)
        #expect(SpokenConfirmationAnswer.classify("don't") == .no)
        #expect(SpokenConfirmationAnswer.classify("don\u{2019}t") == .no)
    }

    @Test func confirmationClassifierMarksNoiseUnclear() {
        #expect(SpokenConfirmationAnswer.classify("hmm what") == .unclear)
        #expect(SpokenConfirmationAnswer.classify("") == .unclear)
    }

    @Test func doRequestClassifierFlagsActionRequests() {
        #expect(DoModeRequestClassifier.utteranceLooksLikeDoRequest("fill this page with my information"))
        #expect(DoModeRequestClassifier.utteranceLooksLikeDoRequest("sign me up for this"))
        #expect(!DoModeRequestClassifier.utteranceLooksLikeDoRequest("where do I change the font size"))
    }
}
