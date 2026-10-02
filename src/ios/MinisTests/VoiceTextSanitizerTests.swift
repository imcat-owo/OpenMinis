import XCTest

/// [T-voice-sanitizer-underscore] Guards the stripMarkdown underscore rules:
/// the trailing cleanup pass must NOT eat underscores inside identifiers
/// (snake_case), while still stripping emphasis markers and boundary
/// underscores. Mirrors the Android port's VoiceTextSanitizerTest cases —
/// the bug was found by those tests during the Kotlin port.
final class VoiceTextSanitizerTests: XCTestCase {

    // MARK: - snake_case survival (the bug)

    func testSnakeCaseSurvivesUnderscoreStripping() {
        XCTAssertEqual(VoiceTextSanitizer.sanitize("call read_image_file now"),
                       "call read_image_file now")
    }

    func testCommonIdentifiersSurvive() {
        XCTAssertEqual(VoiceTextSanitizer.sanitize("tool_use max_tokens session_id"),
                       "tool_use max_tokens session_id")
    }

    // MARK: - Boundary underscores still stripped

    func testLeadingUnderscoreStripped() {
        XCTAssertEqual(VoiceTextSanitizer.sanitize("_leading"), "leading")
    }

    func testTrailingUnderscoreStripped() {
        XCTAssertEqual(VoiceTextSanitizer.sanitize("trailing_"), "trailing")
    }

    // MARK: - Emphasis stripping not loosened

    func testDoubleUnderscoreBoldStripped() {
        XCTAssertEqual(VoiceTextSanitizer.sanitize("__bold__"), "bold")
    }

    func testSingleUnderscoreItalicStripped() {
        XCTAssertEqual(VoiceTextSanitizer.sanitize("an _italic_ word"),
                       "an italic word")
    }

    func testAsteriskAndTildeMarkersStillUnconditional() {
        XCTAssertEqual(VoiceTextSanitizer.sanitize("**bold** ~~gone~~ *i*"),
                       "bold gone i")
    }

    func testInlineCodeWithSnakeCase() {
        // Backticks stripped, identifier inside kept verbatim.
        XCTAssertEqual(VoiceTextSanitizer.sanitize("run `read_image_file` today"),
                       "run read_image_file today")
    }

    // MARK: - withoutParentheses: unclosed-paren guard (AI-P2-11)

    func testWithoutParentheses_balancedSpan_removed() {
        XCTAssertEqual(VoiceTextSanitizer.sanitize("hello (world) foo", mode: .withoutParentheses),
                       "hello foo")
        XCTAssertEqual(VoiceTextSanitizer.sanitize("你好（世界）再见", mode: .withoutParentheses),
                       "你好 再见")
        XCTAssertEqual(VoiceTextSanitizer.sanitize("a (b (c) d) e", mode: .withoutParentheses),
                       "a e")
    }

    func testWithoutParentheses_unclosedParen_keepsOriginal() {
        // Old code swallowed everything after the unclosed `(`.
        XCTAssertEqual(VoiceTextSanitizer.sanitize("hello (world", mode: .withoutParentheses),
                       "hello (world")
        XCTAssertEqual(VoiceTextSanitizer.sanitize("a) b (c", mode: .withoutParentheses),
                       "a) b (c")
    }
}
