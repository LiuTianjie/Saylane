import Foundation

@main struct NumeralFormatTests {
    static func main() {
        var passed = 0
        func same(_ model: String, _ system: String, _ expected: String, line: UInt = #line) {
            let got = NumeralFormat.followingSystem(model: model, system: system)
            precondition(got == expected, "line \(line): \(got)")
            passed += 1
        }
        // What was heard on device and with synthesized speech: the model spells numbers out.
        same("我现在这个输入法在M一芯片的机器上，会不会效果比较差？", "我现在这个输入法在 M1芯片的机器上会不会效果比较差",
             "我现在这个输入法在M1芯片的机器上，会不会效果比较差？")
        same("我用的是iPhone十五Pro，系统是iOS十八，跑GPT四核A幺七芯片的测试。", "我用的是 iPhone 15 Pro系统是 ioS 18好 GPT四和 A17芯片的测试",
             "我用的是iPhone 15 Pro，系统是iOS 18，跑GPT四核A17芯片的测试。")
        same("这台电脑有三十六G内存，用的是USB C接口和五G网络。订单号是R三百八十。", "这台电脑有 36G内存用的是 USBC接口和 5G网络订单号是380",
             "这台电脑有36G内存，用的是USB C接口和5G网络。订单号是R380。")
        same("他架起M十六步枪。", "他架起他的 M 16步枪", "他架起M16步枪。")
        // The right 一 is replaced, not the first one.
        same("我有一个M一芯片的电脑，一共用了一年。", "我有一个 M1芯片的电脑一共用了一年", "我有一个M1芯片的电脑，一共用了一年。")
        // Different numbers: the model's hearing stays.
        same("一共三十六个人。", "一共26个人", "一共三十六个人。")
        // The system wrote characters: nothing to follow.
        same("第一次去北京，待了三天。", "第一次去北京待了三天", "第一次去北京，待了三天。")
        // Decimals, bigger numbers, digit by digit.
        same("涨了三点五个百分点，一共一千二百人，电话是幺三八零零。", "涨了3.5个百分点一共1200人电话是13800",
             "涨了3.5个百分点，一共1200人，电话是13800。")
        same("二零二六年十月二号下午三点开会。", "2026年10月2号下午3点开会", "2026年10月2号下午3点开会。")
        // Thousands separators, percentages and times, the way the system writes them.
        same("该城镇人口数量不足四万。", "该城镇人口数量不足 40,000", "该城镇人口数量不足40,000。")
        same("亚马逊河占全世界河流入海流量的百分之二十。", "亚马逊河占全世界河流入海流量的 20%", "亚马逊河占全世界河流入海流量的20%。")
        same("消防人员最终在晚上十一点三十五分扑灭了大火。", "消防人员最终在晚上 11:35扑灭了大火", "消防人员最终在晚上11:35扑灭了大火。")
        // An hour alone is left as the model wrote it: 两点 is also "two points".
        same("晚上十点到十一点之间引发了一场火灾。", "晚上 10:00到 11:00之间引发了一场火灾", "晚上十点到十一点之间引发了一场火灾。")
        same("车辆在两点之间的运动。", "车辆在 2:00之间的运动", "车辆在两点之间的运动。")
        same("九点半开会，三点零五分结束。", "9:30开会 3:05结束", "9:30开会，3:05结束。")
        // A score is not a number of minutes, and three points are not a percentage.
        same("最后得了三分。", "最后得了3分", "最后得了3分。")
        same("百分之二十的人同意。", "30%的人同意", "百分之二十的人同意。")
        // English is left alone.
        same("Meet at five thirty.", "Meet at 5:30.", "Meet at five thirty.")
        same("", "123", ""); same("没有数字", "", "没有数字")
        for (spelled, digits) in [("三十六", "36"), ("十五", "15"), ("三百八", "380"), ("三百八十", "380"), ("三百零八", "308"),
                                  ("一万二", "12000"), ("两千零二十六", "2026"), ("一五", "15"), ("幺七", "17"), ("十", "10"), ("二十", "20")] {
            precondition(NumeralFormat.readings(of: spelled).contains(digits), "\(spelled) → \(NumeralFormat.readings(of: spelled))")
            passed += 1
        }
        print("NumeralFormatTests: \(passed) checks passed")
    }
}
