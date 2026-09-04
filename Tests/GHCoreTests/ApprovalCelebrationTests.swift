import XCTest
@testable import GHCore

final class ApprovalCelebrationTests: XCTestCase {
    func testMemeAllowlistContainsOnlyReviewedURLs() {
        XCTAssertEqual(
            ApprovalCelebration.allowedMemeURLs.map(\.absoluteString),
            [
                "https://media2.giphy.com/media/bx8tQ1edbvZxGnNMlw/200w.gif?cid=b789dec05m71ypb3sf44yr6xtdi8xh1nrw1huedldkrommxy&ep=v1_gifs_search&rid=200w.gif&ct=g",
                "https://media1.giphy.com/media/111ebonMs90YLu/200w.gif?cid=b789dec0rup4zctr3ssfg36i6dvfr4niegyo5rc2lqevcscq&ep=v1_gifs_search&rid=200w.gif&ct=g"
            ]
        )
    }

    func testOnlySixSelectsMemePath() {
        for dieRoll in 1...5 {
            guard case .emoji = ApprovalCelebration.selection(dieRoll: dieRoll, itemIndex: 0) else {
                return XCTFail("Die roll \(dieRoll) should select the emoji path.")
            }
        }

        guard case .meme = ApprovalCelebration.selection(dieRoll: 6, itemIndex: 0) else {
            return XCTFail("Die roll 6 should select the meme path.")
        }
    }

    func testMemeSelectionRendersAsInlineGitHubMarkdown() {
        let celebration = ApprovalCelebration.selection(dieRoll: 6, itemIndex: 1)

        XCTAssertEqual(
            celebration.markdown,
            "![Approval celebration](\(ApprovalCelebration.allowedMemeURLs[1].absoluteString))"
        )
    }
}
