import Foundation

struct PinyinCandidate: Equatable {
    var word: String
    var preview: String
    var pinyin: String
    var inputLength: Int
    var frequency: Int
    var commitsAll: Bool
    var engineIndex: Int?
    var comment: String

    init(word: String, pinyin: String, inputLength: Int, frequency: Int, preview: String? = nil,
         commitsAll: Bool = false, engineIndex: Int? = nil, comment: String = "") {
        self.word = word
        self.preview = preview ?? word
        self.pinyin = pinyin
        self.inputLength = inputLength
        self.frequency = frequency
        self.commitsAll = commitsAll
        self.engineIndex = engineIndex
        self.comment = comment
    }
}
