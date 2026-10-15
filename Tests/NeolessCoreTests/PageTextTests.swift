import Testing
@testable import NeolessCore

@Suite struct MixedTextTests {
    @Test func spaceOnlyNextToLatin() {
        #expect(MixedText.join("输入到", "微信") == "输入到微信")
        #expect(MixedText.join("输入到", "Claude") == "输入到 Claude")
        #expect(MixedText.join("在", "VS Code", "里") == "在 VS Code 里")
        #expect(MixedText.join("在", "Visual Studio Code", "里改的字") == "在 Visual Studio Code 里改的字")
        #expect(MixedText.join("在", "微信", "里改的字") == "在微信里改的字")
        #expect(MixedText.join("正在用", "内置麦克风") == "正在用内置麦克风")
        #expect(MixedText.join("正在用", "MacBook Pro麦克风") == "正在用 MacBook Pro麦克风")
        #expect(MixedText.join("输入到", "1Password") == "输入到 1Password")
        #expect(MixedText.join("Codex", "Desktop") == "Codex Desktop")
    }

    @Test func punctuationAndEmptyPiecesAddNothing() {
        #expect(MixedText.join("“", "Claude", "”") == "“Claude”")
        #expect(MixedText.join("输入到 ", "Claude") == "输入到 Claude")
        #expect(MixedText.join("输入到", "", "微信") == "输入到微信")
        #expect(MixedText.join("在", "Café", "里") == "在 Café 里")
        #expect(MixedText.join([]) == "")
    }
}

@Suite struct RecordNoteTests {
    @Test func notesBecomeSentences() {
        #expect(RecordNote.display(nil) == nil)
        #expect(RecordNote.display("") == nil)
        #expect(RecordNote.display("整理超时") == "整理超时。")
        #expect(RecordNote.display("整理超时；没找到输入框，只复制了") == "整理超时。没找到输入框，只复制了。")
        // Already a sentence: no second full stop.
        #expect(RecordNote.display("麦克风中途出错。") == "麦克风中途出错。")
    }

    @Test func theDoneLineIsNotRepeatedInTheCard() {
        // Copied: the line under the headline says why.
        let copied = InsertResult.copiedAppChanged
        #expect(RecordNote.beyond(doneMessage: copied.message, note: copied.detail) == nil)
        // The clipboard could not be put back: said once.
        let kept = InsertResult.pastedKeptOnClipboard
        #expect(RecordNote.beyond(doneMessage: kept.message, note: kept.detail) == nil)
        // Not polished and copied: the reason is in the line, and so is the copy.
        let fallback = "\(InsertResult.copiedNoField.message) · 整理超时"
        #expect(RecordNote.beyond(doneMessage: fallback, note: "整理超时；\(InsertResult.copiedNoField.detail!)") == nil)
        // An expired login: the line names it, the card does not repeat it.
        let expired = FailureText.typedRaw(reason: "ChatGPT 登录已过期")
        #expect(RecordNote.beyond(doneMessage: expired, note: "ChatGPT 登录已过期，在设置里重新登录") == nil)
        // Esc: the headline says 已取消输入.
        #expect(RecordNote.beyond(doneMessage: DoneText.pasteCancelled(keepHistory: true),
                                  note: RecordNote.pasteCancelled) == nil)
    }

    @Test func whatTheLineDoesNotSayStays() {
        // About the recording itself.
        let salvage = FinishReason.salvage.note!
        #expect(RecordNote.beyond(doneMessage: InsertResult.pasted.message, note: salvage) == salvage + "。")
        #expect(RecordNote.beyond(doneMessage: InsertResult.copiedNoField.message,
                                  note: "\(CaptureText.incomplete)；\(InsertResult.copiedNoField.detail!)")
                == CaptureText.incomplete + "。")
        // A later 重新整理 that failed after a plain 已输入: the line says nothing about it.
        #expect(RecordNote.beyond(doneMessage: InsertResult.pasted.message, note: "整理超时") == "整理超时。")
    }

    @Test func everyInsertDetailIsShortAndPlain() {
        for result in InsertResult.allCases {
            guard let detail = result.detail else { continue }
            #expect(detail.count <= 24, "\(detail)")
            #expect(!detail.hasSuffix("。"))
            #expect(!detail.contains("；"))
        }
    }
}
