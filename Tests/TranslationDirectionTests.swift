import Foundation
@main struct TranslationDirectionTests {
    static func main() {
        for source in AppLanguage.allCases {
            for target in AppLanguage.allCases {
                let original = TranslationDirection(source: source, target: target)
                precondition(original.reversed.source == target)
                precondition(original.reversed.target == source)
                precondition(original.reversed.reversed == original)
            }
        }
        let forward = TranslationDirection(source: .en, target: .zhHans)
        precondition(forward.reversed == TranslationDirection(source: .zhHans, target: .en))

        let a = AppLanguage.en
        let b = AppLanguage.ja
        let modes = TranslationDirection.voiceModes(a: a, b: b)
        precondition(modes == [
            TranslationDirection(source: .en, target: .en),
            TranslationDirection(source: .en, target: .ja),
            TranslationDirection(source: .ja, target: .en),
            TranslationDirection(source: .ja, target: .ja)
        ])
        var current = TranslationDirection(source: a, target: b)
        current = TranslationDirection.cycled(current: current, a: a, b: b)
        precondition(current == TranslationDirection(source: .ja, target: .en))
        current = TranslationDirection.cycled(current: current, a: a, b: b)
        precondition(current == TranslationDirection(source: .ja, target: .ja))
        current = TranslationDirection.cycled(current: current, a: a, b: b)
        precondition(current == TranslationDirection(source: .en, target: .en))
        current = TranslationDirection.cycled(current: current, a: a, b: b)
        precondition(current == TranslationDirection(source: .en, target: .ja))
        print("PASS: pair languages cycle A-A / A-B / B-A / B-B")
    }
}
