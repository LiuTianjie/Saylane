import Foundation

/// Full-syllable inventory used only to tell pinyin-in-progress from English.
enum PinyinSyllable {
    static let all: Set<String> = [
        "a", "ai", "an", "ang", "ao",
        "ba", "bai", "ban", "bang", "bao", "bei", "ben", "beng", "bi", "bian", "biao", "bie", "bin", "bing", "bo", "bu",
        "ca", "cai", "can", "cang", "cao", "ce", "cei", "cen", "ceng", "ci", "cong", "cou", "cu", "cuan", "cui", "cun", "cuo",
        "cha", "chai", "chan", "chang", "chao", "che", "chen", "cheng", "chi", "chong", "chou", "chu", "chua", "chuai",
        "chuan", "chuang", "chui", "chun", "chuo",
        "da", "dai", "dan", "dang", "dao", "de", "dei", "den", "deng", "di", "dia", "dian", "diao", "die", "ding", "diu",
        "dong", "dou", "du", "duan", "dui", "dun", "duo",
        "e", "ei", "en", "eng", "er",
        "fa", "fan", "fang", "fei", "fen", "feng", "fiao", "fo", "fou", "fu",
        "ga", "gai", "gan", "gang", "gao", "ge", "gei", "gen", "geng", "gong", "gou", "gu", "gua", "guai", "guan", "guang",
        "gui", "gun", "guo",
        "ha", "hai", "han", "hang", "hao", "he", "hei", "hen", "heng", "hong", "hou", "hu", "hua", "huai", "huan", "huang",
        "hui", "hun", "huo",
        "ji", "jia", "jian", "jiang", "jiao", "jie", "jin", "jing", "jiong", "jiu", "ju", "juan", "jue", "jun",
        "ka", "kai", "kan", "kang", "kao", "ke", "kei", "ken", "keng", "kong", "kou", "ku", "kua", "kuai", "kuan", "kuang",
        "kui", "kun", "kuo",
        "la", "lai", "lan", "lang", "lao", "le", "lei", "leng", "li", "lia", "lian", "liang", "liao", "lie", "lin", "ling",
        "liu", "lo", "long", "lou", "lu", "luan", "lue", "lun", "luo", "lv", "lve",
        "ma", "mai", "man", "mang", "mao", "me", "mei", "men", "meng", "mi", "mian", "miao", "mie", "min", "ming", "miu",
        "mo", "mou", "mu",
        "n", "na", "nai", "nan", "nang", "nao", "ne", "nei", "nen", "neng", "ng", "ni", "nian", "niang", "niao", "nie",
        "nin", "ning", "niu", "nong", "nou", "nu", "nuan", "nue", "nun", "nuo", "nv", "nve",
        "o", "ou",
        "pa", "pai", "pan", "pang", "pao", "pei", "pen", "peng", "pi", "pian", "piao", "pie", "pin", "ping", "po", "pou", "pu",
        "qi", "qia", "qian", "qiang", "qiao", "qie", "qin", "qing", "qiong", "qiu", "qu", "quan", "que", "qun",
        "ran", "rang", "rao", "re", "ren", "reng", "ri", "rong", "rou", "ru", "rua", "ruan", "rui", "run", "ruo",
        "sa", "sai", "san", "sang", "sao", "se", "sen", "seng", "si", "song", "sou", "su", "suan", "sui", "sun", "suo",
        "sha", "shai", "shan", "shang", "shao", "she", "shei", "shen", "sheng", "shi", "shou", "shu", "shua", "shuai",
        "shuan", "shuang", "shui", "shun", "shuo",
        "ta", "tai", "tan", "tang", "tao", "te", "tei", "teng", "ti", "tian", "tiao", "tie", "ting", "tong", "tou", "tu",
        "tuan", "tui", "tun", "tuo",
        "wa", "wai", "wan", "wang", "wei", "wen", "weng", "wo", "wu",
        "xi", "xia", "xian", "xiang", "xiao", "xie", "xin", "xing", "xiong", "xiu", "xu", "xuan", "xue", "xun",
        "ya", "yan", "yang", "yao", "ye", "yi", "yin", "ying", "yo", "yong", "you", "yu", "yuan", "yue", "yun",
        "za", "zai", "zan", "zang", "zao", "ze", "zei", "zen", "zeng", "zi", "zong", "zou", "zu", "zuan", "zui", "zun", "zuo",
        "zha", "zhai", "zhan", "zhang", "zhao", "zhe", "zhei", "zhen", "zheng", "zhi", "zhong", "zhou", "zhu", "zhua",
        "zhuai", "zhuan", "zhuang", "zhui", "zhun", "zhuo"
    ]

    private static let weakSyllables: Set<String> = ["a", "e", "o", "n", "m", "ng"]

    private static let prefixes: Set<String> = {
        var set = Set<String>()
        for syllable in all {
            var prefix = ""
            for character in syllable {
                prefix.append(character)
                set.insert(prefix)
            }
        }
        return set
    }()

    static func coversQuanpin(_ input: String) -> Bool {
        let chars = Array(input)
        guard !chars.isEmpty else { return false }
        var complete = Array(repeating: false, count: chars.count + 1)
        complete[0] = true
        for index in 0..<chars.count where complete[index] {
            for length in 1...6 {
                let end = index + length
                guard end <= chars.count else { break }
                let piece = String(chars[index..<end])
                if length == 1 && end != chars.count && weakSyllables.contains(piece) { continue }
                if all.contains(piece) { complete[end] = true }
            }
        }
        if complete[chars.count] { return true }
        for index in 0..<chars.count where complete[index] {
            if prefixes.contains(String(chars[index...])) { return true }
        }
        return false
    }

    static func segment(_ input: String) -> [String]? {
        let chars = Array(input)
        var previous = Array(repeating: -1, count: chars.count + 1)
        previous[0] = 0
        for index in 0..<chars.count where previous[index] >= 0 {
            for length in (1...6).reversed() {
                let end = index + length
                guard end <= chars.count else { continue }
                let piece = String(chars[index..<end])
                if length == 1 && end != chars.count && weakSyllables.contains(piece) { continue }
                if all.contains(piece) && previous[end] < 0 { previous[end] = index }
            }
        }
        guard previous[chars.count] >= 0 else { return nil }
        var parts: [String] = []
        var end = chars.count
        while end > 0 {
            let start = previous[end]
            parts.append(String(chars[start..<end]))
            end = start
        }
        return parts.reversed()
    }
}
