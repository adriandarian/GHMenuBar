import Foundation

enum ApprovalCelebration: Equatable, Sendable {
    case emoji(String)
    case meme(URL)

    // Keep these lists closed and reviewable. Agent output must never supply a
    // meme URL: it may only receive the single value selected here.
    static let allowedEmojis = [
        "✅",
        "👍",
        "🚀",
        "🎉",
        "🙌",
        "💯"
    ]

    static let allowedMemeURLs = [
        URL(string: "https://media2.giphy.com/media/bx8tQ1edbvZxGnNMlw/200w.gif?cid=b789dec05m71ypb3sf44yr6xtdi8xh1nrw1huedldkrommxy&ep=v1_gifs_search&rid=200w.gif&ct=g")!,
        URL(string: "https://media1.giphy.com/media/111ebonMs90YLu/200w.gif?cid=b789dec0rup4zctr3ssfg36i6dvfr4niegyo5rc2lqevcscq&ep=v1_gifs_search&rid=200w.gif&ct=g")!
    ]

    static var allowedMarkdownValues: [String] {
        allowedEmojis + allowedMemeURLs.map {
            "![Approval celebration](\($0.absoluteString))"
        }
    }

    var markdown: String {
        switch self {
        case .emoji(let emoji):
            return emoji
        case .meme(let url):
            return "![Approval celebration](\(url.absoluteString))"
        }
    }

    static func random() -> ApprovalCelebration {
        let dieRoll = Int.random(in: 1...6)
        let itemCount = dieRoll == 6 ? allowedMemeURLs.count : allowedEmojis.count
        return selection(
            dieRoll: dieRoll,
            itemIndex: Int.random(in: 0..<itemCount)
        )
    }

    static func selection(dieRoll: Int, itemIndex: Int) -> ApprovalCelebration {
        precondition((1...6).contains(dieRoll), "Approval celebration die roll must be between 1 and 6.")

        if dieRoll == 6 {
            return .meme(allowedMemeURLs[itemIndex % allowedMemeURLs.count])
        }
        return .emoji(allowedEmojis[itemIndex % allowedEmojis.count])
    }
}
