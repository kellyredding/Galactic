import XCTest
@testable import Galactic

/// Whether a bare carriage return commits a prompt in the session pane.
///
/// This is the question `SessionSubmit.bytes` branches on, and both wrong
/// answers fail the same silent way: a carriage return where the reserved chord
/// was needed leaves a prompt fully typed and uncommitted, and the chord where a
/// carriage return was needed is ignored outright. There is no echo and no
/// error either way, so nothing downstream can notice.
///
/// The answer is a pure function of the file's contents, which is why these
/// feed a document rather than a filesystem. Every case below is a state a real
/// `~/.claude/keybindings.json` can be in.
final class ClaudeKeybindingsReadTests: XCTestCase {

    /// Build a keybindings document with `bindings` in the Chat context.
    private func document(
        chat bindings: [String: Any],
        context: String = "Chat"
    ) -> [String: Any] {
        [
            "$schema": "https://www.schemastore.org/claude-code-keybindings.json",
            "bindings": [["context": context, "bindings": bindings]],
        ]
    }

    /// What the pane will actually do with Return, given a document.
    ///
    /// Deliberately the same function `plainReturnSubmits` calls, rather than
    /// its steps reassembled here. Reassembling them would let the property
    /// ask the narrowed question again — the original defect — with every test
    /// below still passing.
    private func returnSubmits(_ root: [String: Any]) -> Bool {
        ClaudeKeybindingsWriter.returnSubmits(in: root)
    }

    // MARK: - The file is silent about Return

    func testAnAbsentFileLeavesClaudeCodesDefaultInForce() {
        XCTAssertTrue(returnSubmits([:]))
    }

    func testADocumentWithNoChatBlockLeavesTheDefaultInForce() {
        let root = document(chat: ["enter": "chat:newline"], context: "Autocomplete")
        XCTAssertTrue(returnSubmits(root))
    }

    func testAChatBlockThatNeverMentionsReturnLeavesTheDefaultInForce() {
        XCTAssertTrue(returnSubmits(document(chat: ["ctrl+j": NSNull()])))
    }

    // MARK: - The file speaks about Return, in this app's vocabulary

    func testReturnBoundToSubmitSubmits() {
        XCTAssertTrue(returnSubmits(document(chat: ["enter": "chat:submit"])))
    }

    func testReturnBoundToNewlineDoesNotSubmit() {
        XCTAssertFalse(returnSubmits(document(chat: ["enter": "chat:newline"])))
    }

    /// An explicit null *removes* a default rather than overriding it, so
    /// Return ends up bound to nothing at all.
    func testReturnExplicitlyUnboundDoesNotSubmit() {
        XCTAssertFalse(returnSubmits(document(chat: ["enter": NSNull()])))
    }

    // MARK: - The file speaks about Return in somebody else's vocabulary

    /// The Chat context has sixteen actions and this app owns two of them.
    /// Reading only its own two left the `enter: chat:submit` default
    /// apparently in force, which answered true and sent a carriage return
    /// into a key bound to something entirely different.
    func testReturnBoundToAnotherChatActionDoesNotSubmit() {
        for action in [
            "chat:cancel", "chat:clearInput", "chat:undo",
            "chat:externalEditor", "chat:stash", "chat:modelPicker",
        ] {
            XCTAssertFalse(
                returnSubmits(document(chat: ["enter": action])),
                "enter bound to \(action) must not read as submitting")
        }
    }

    func testReturnBoundToACommandDoesNotSubmit() {
        XCTAssertFalse(returnSubmits(document(chat: ["enter": "command:my-thing"])))
    }

    func testReturnBoundToAnActionFromAnotherCategoryDoesNotSubmit() {
        XCTAssertFalse(returnSubmits(document(chat: ["enter": "app:interrupt"])))
    }

    // MARK: - The two questions stay separate

    /// A foreign binding is not this app's to claim. The narrowed read backs
    /// the settings comparison, and adopting somebody else's action there
    /// would write it back into the file as though this app had chosen it.
    func testTheNarrowedReadStillIgnoresForeignActions() {
        let root = document(chat: ["enter": "chat:cancel", "ctrl+j": "chat:newline"])
        let owned = ClaudeKeybindingsWriter.chatEntries(in: root, ownedOnly: true)

        XCTAssertNil(owned["enter"])
        XCTAssertEqual(owned["ctrl+j"], "chat:newline")
    }

    /// Both reads agree that an explicit unbind is an unbind — it is a
    /// statement about a default, not a binding anyone owns.
    func testBothReadsKeepAnExplicitUnbind() {
        let root = document(chat: ["enter": NSNull()])

        for ownedOnly in [true, false] {
            let entries = ClaudeKeybindingsWriter.chatEntries(
                in: root, ownedOnly: ownedOnly)
            XCTAssertTrue(
                entries.keys.contains("enter"),
                "ownedOnly: \(ownedOnly) dropped the unbind")
            XCTAssertEqual(
                entries["enter"], .some(nil),
                "ownedOnly: \(ownedOnly) did not record it as an unbind")
        }
    }
}
