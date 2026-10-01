import Foundation

/// Which keys do what while candidates are showing. Chosen in the settings,
/// applied by the input method.
struct PinyinKeyOptions: Codable, Equatable, Sendable {
    /// Keys that turn the candidate page. Page Up and Page Down always do.
    var pageWithMinusEqual = true
    var pageWithCommaPeriod = false
    var pageWithBrackets = false
    var pageWithTab = true
    /// `;` and `'` pick the second and the third candidate.
    var pickWithSemicolonQuote = false
    /// Western punctuation while typing Chinese.
    var englishPunctuation = false
}
