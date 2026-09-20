import Foundation

/// Domain terminology for dictation repair: math, science, computing, biochemistry
/// and current internet usage. Everyday homophones (微信/威信, 翻译) stay out.
enum DictationGlossary {
    static let entries: [SpeechHotwords.Entry] = SpeechHotwords.entries(
        [mathematics, science, computing, programming, biochemistry, internet].joined(separator: "\n"),
        limit: nil
    )

    /// Bundled terms plus titles harvested from Wikimedia categories. Bundled spellings win.
    static func combined(remote: [String] = []) -> [SpeechHotwords.Entry] {
        var seen = Set(entries.map(\.canonical))
        var extra: [SpeechHotwords.Entry] = []
        extra.reserveCapacity(min(remote.count, 800))
        for title in remote {
            guard let term = remoteTerm(fromTitle: title), seen.insert(term).inserted else { continue }
            extra.append(.init(canonical: term, aliases: []))
            if extra.count == 800 { break }
        }
        return entries + extra
    }

    static func biasTerms(userRaw: String, includeUser: Bool, includeGlossary: Bool,
                          remote: [String] = [], limit: Int = 50) -> [String] {
        var seen = Set<String>()
        var terms: [String] = []
        if includeUser {
            for term in SpeechHotwords.terms(userRaw) where seen.insert(term).inserted {
                terms.append(term)
                if terms.count == limit { return terms }
            }
        }
        if includeGlossary {
            // Aliases are known mishearings; send those to the recognizer first.
            let ranked = combined(remote: remote).sorted {
                if $0.aliases.count != $1.aliases.count { return $0.aliases.count > $1.aliases.count }
                return $0.canonical.count > $1.canonical.count
            }
            for entry in ranked where seen.insert(entry.canonical).inserted {
                terms.append(entry.canonical)
                if terms.count == limit { return terms }
            }
        }
        return terms
    }

    /// Wikimedia page titles are noisy (lists, one-character memes, ordinary speech).
    /// Keep distinctive domain and internet terms only; convert to simplified Chinese.
    static func remoteTerm(fromTitle title: String) -> String? {
        var text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let open = text.lastIndex(of: "(") ?? text.lastIndex(of: "（") {
            let rest = text[text.index(after: open)...]
            if rest.last == ")" || rest.last == "）" {
                text = String(text[..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        text = text.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? text
        guard !text.isEmpty, text.count <= 12 else { return nil }
        guard text.range(of: #"[/\\#\[\]{}<>|_]"#, options: .regularExpression) == nil else { return nil }
        if text.contains("列表") || text.contains("概述") || text.contains("条目")
            || text.contains("主题") || text.contains("不支援") { return nil }
        if text.hasSuffix("术语") || text.hasSuffix("名词") { return nil }
        if text.unicodeScalars.contains(where: { CharacterSet.decimalDigits.contains($0) }) { return nil }
        if everyday.contains(text) { return nil }
        let han = text.unicodeScalars.filter(isHanScalar).count
        let letters = text.unicodeScalars.filter { $0.isASCII && CharacterSet.letters.contains($0) }.count
        // Two-character Chinese words are mostly ordinary speech even inside
        // "术语" categories (定理、苹果、功能). Distinctive 2-char terms stay in the bundle.
        if han == text.count, (3...12).contains(han) { return text }
        if han >= 1, letters >= 1, (2...8).contains(text.count) { return text }
        if han == 0, letters == text.count, (3...12).contains(letters),
           !commonEnglish.contains(text.lowercased()) { return text }
        return nil
    }

    private static func isHanScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F: return true
        default: return false
        }
    }

    /// Ordinary speech that Wikimedia categories still list. Matching these would rewrite daily words.
    private static let everyday: Set<String> = [
        "微信", "翻译", "复制", "细胞", "分子", "计算", "几乎", "定义", "严谨",
        "加速", "可爱", "出征", "包子", "南梁", "工作", "生活", "因为", "所以",
        "可以", "如果", "什么", "我们", "这个", "那个", "没有", "一个", "自己",
        "现在", "知道", "觉得", "问题", "时候", "东西", "打开", "关闭", "系统",
        "网络", "电脑", "手机", "应用", "设置", "文件", "图片", "视频", "音乐",
        "游戏", "软件", "消息", "电话", "中国", "美国", "日本", "北京", "上海",
        "今天", "明天", "小时", "分钟", "朋友", "老师", "学生", "公司", "学校",
        "喜欢", "谢谢", "再见", "请问", "怎么", "哈哈", "呵呵",
        "为什么", "怎么办", "对不起", "没关系", "实际上", "基本上",
        "特别是", "就是说", "没问题", "不知道", "看起来", "相当于",
        "非洲人", "蒙古人", "瑞典人", "美国人", "日本人", "中国人",
    ]

    private static let commonEnglish: Set<String> = [
        "the", "and", "for", "you", "are", "not", "but", "all", "can", "has",
        "was", "were", "this", "that", "with", "from", "have", "will", "your",
        "dog", "cat", "hi", "hey", "lol", "gg", "ok", "okay", "yes", "no",
        "up", "to", "on", "in", "of", "or", "if", "it", "is", "be", "we", "me",
    ]

    /// Distinctive math terms. Skip 极限/无穷 — they are ordinary words.
    private static let mathematics = """
    微积分
    线性代数
    概率论
    数理统计
    离散数学
    实变函数
    复变函数
    泛函分析
    偏微分方程
    常微分方程
    泰勒展开
    傅里叶|傅立叶
    拉普拉斯
    特征值
    特征向量
    最小二乘
    协方差
    标准差
    正态分布
    泊松分布
    二项分布
    卡方检验
    假设检验
    置信区间
    最大似然
    贝叶斯
    梯度下降
    牛顿法
    拉格朗日
    欧拉公式
    黄金分割
    圆周率
    排列组合
    最大公约数
    最小公倍数
    质因数
    三角函数
    反函数
    复合函数
    隐函数
    偏导数
    方向导数
    二重积分
    三重积分
    曲面积分
    线积分
    雅可比
    海森矩阵
    奇异值
    主成分
    线性回归
    逻辑回归
    过拟合
    欠拟合
    正则化
    交叉验证
    损失函数
    激活函数
    反向传播
    行列式
    逆矩阵
    转置矩阵
    正交矩阵
    齐次方程
    通解
    特解
    特征多项式
    向量空间
    内积
    外积
    叉乘
    点乘
    散度
    旋度
    梯度
    """

    private static let science = """
    量子力学
    相对论
    热力学
    电磁学
    流体力学
    固体物理
    凝聚态
    粒子物理
    天体物理
    引力波
    中子星
    夸克
    中微子
    波粒二象性
    不确定性原理
    薛定谔
    海森堡
    麦克斯韦
    普朗克
    玻尔兹曼
    阿伏伽德罗
    理想气体
    元素周期表
    有机化学
    无机化学
    分析化学
    物理化学
    共价键
    离子键
    金属键
    氢键
    氧化还原
    摩尔质量
    物质的量
    化学平衡
    勒夏特列
    光合作用
    细胞呼吸
    生态系统
    生物多样性
    自然选择
    基因突变
    古生物学
    地质年代
    板块构造
    温室效应
    臭氧层
    碳循环
    氮循环
    苯环
    羟基
    羧基
    氨基
    甲基
    乙基
    烷基
    酯化
    皂化
    水解反应
    聚合反应
    同分异构
    对映体
    手性分子
    """

    private static let computing = """
    时间复杂度
    空间复杂度
    哈希表|哈西表
    二叉树
    红黑树
    最短路径
    动态规划
    贪心算法
    分治算法
    深度优先
    广度优先
    互斥锁
    信号量
    内存泄漏
    垃圾回收
    虚拟机
    容器化
    微服务
    负载均衡
    反向代理
    域名解析
    公钥
    私钥
    对称加密
    非对称加密
    数字签名
    智能合约
    区块链
    编译器
    解释器
    运行时
    包管理器
    依赖注入
    设计模式
    单例模式
    工厂模式
    观察者模式
    抽象类
    泛型|范型
    闭包
    协程
    死锁
    并发
    并行
    异步
    WebSocket
    GraphQL
    gRPC
    PostgreSQL|Postgres
    MongoDB
    NoSQL
    隔离级别
    持续集成
    持续交付
    单元测试
    集成测试
    回归测试
    代码审查
    版本控制
    灰度发布
    蓝绿部署
    金丝雀发布
    服务网格
    可观测性
    链路追踪
    日志聚合
    子网掩码
    IP地址
    """

    /// Field vocabulary, not consumer app names. Short English words (class/code/bug) stay out.
    private static let programming = """
    Python|派森|拍森
    JavaScript
    TypeScript
    Kubernetes
    PyTorch
    TensorFlow
    FastAPI
    CUDA
    NVIDIA|英伟达
    Golang
    Kotlin
    Haskell
    Linux
    Redis
    Nginx
    Django
    Flask
    React
    Hugging Face
    LangChain
    Transformer
    卷积神经网络
    循环神经网络
    注意力机制
    词嵌入
    强化学习
    监督学习
    无监督学习
    预训练
    多模态
    提示词
    大模型
    生成式
    向量数据库
    检索增强
    工作流
    知识库
    算力
    参数量
    上下文窗口
    量化部署
    模型蒸馏
    微调
    LoRA
    RLHF
    """

    /// Skip 翻译/复制/细胞/分子 — ordinary speech uses them constantly.
    private static let biochemistry = """
    脱氧核糖核酸
    核糖核酸
    信使RNA|mRNA
    转运RNA|tRNA
    核糖体RNA|rRNA
    氨基酸
    多肽链
    酶活性
    活性位点
    辅酶
    糖酵解
    三羧酸循环|柠檬酸循环
    氧化磷酸化
    电子传递链
    线粒体
    叶绿体
    核糖体
    内质网
    高尔基体
    溶酶体
    染色质
    转录因子
    基因表达
    表观遗传
    甲基化
    磷酸化
    糖基化
    CRISPR
    限制性内切酶
    质粒
    蛋白质组
    代谢组
    激酶
    磷酸酶
    信号通路
    细胞凋亡
    细胞周期
    诱导多能
    血红蛋白
    葡萄糖
    脂肪酸
    磷脂
    胆固醇
    胰岛素
    抗原表位
    免疫应答
    NADH
    FADH
    ATP
    PCR
    """

    /// Current colloquial and platform usage. Skip 冲/润/寄 — too short or too common.
    private static let internet = """
    内卷
    躺平
    摆烂
    破防
    绝绝子
    拿捏
    整活
    出圈
    社死
    打工人
    干饭人
    吃瓜
    真香
    奥利给
    栓Q
    绷不住
    笑不活
    赢麻了
    家人们
    显眼包
    精神内耗
    情绪价值
    松弛感
    硬控
    班味
    搭子
    特种兵式
    电子榨菜
    数字游民
    人生进度条
    尊嘟假嘟
    遥遥领先
    多巴胺
    皮质醇
    去中心化
    元宇宙
    虚拟人
    数字藏品
    直播间
    种草
    拔草
    二创
    鬼畜
    弹幕
    热搜
    破圈
    塌房
    洗白
    吃瓜群众
    键盘侠
    引战
    开盒
    AIGC
    yyds
    xswl
    awsl
    """
}
