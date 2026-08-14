import Foundation

/// A second, mutually-exclusive level inside each broad smart collection.
/// The order of the cases is intentional: specific meanings win before the
/// fallback bucket, so every parent is completely partitioned by its children.
enum SmartSubcollection: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case transitionRiser, transitionDowner, transitionPassBy, transitionReverse
    case transitionSweep, transitionWhoosh, transitionOther
    case ambienceWeather, ambienceWind, ambienceWater, ambienceNature
    case ambienceCity, ambienceInterior, ambienceCrowd, ambienceDark, ambienceOther
    case impactExplosion, impactBoom, impactMetal, impactBreak
    case impactPunch, impactCinematic, impactHit, impactOther
    case foleyFootsteps, foleyDoors, foleyCloth, foleyHands, foleyObjects
    case foleyKitchen, foleyVehicles, foleyWeapons, foleyMovement, foleyOther
    case voiceDialogue, voiceShout, voiceReaction, voiceCrowd, voiceCreature
    case voiceChoir, voiceChild, voiceMale, voiceFemale, voiceOther
    case musicLoop, musicStinger, musicPiano, musicStrings, musicGuitar
    case musicPercussion, musicElectronic, musicCinematic, musicAmbient, musicOther
    case technologyClick, technologyNotification, technologyGlitch, technologyComputer
    case technologySciFi, technologyGame, technologyScan, technologyPower, technologyOther

    var id: String { rawValue }

    var parent: SmartCollection {
        switch self {
        case .transitionRiser, .transitionDowner, .transitionPassBy, .transitionReverse,
             .transitionSweep, .transitionWhoosh, .transitionOther:
            return .transition
        case .ambienceWeather, .ambienceWind, .ambienceWater, .ambienceNature,
             .ambienceCity, .ambienceInterior, .ambienceCrowd, .ambienceDark, .ambienceOther:
            return .ambience
        case .impactExplosion, .impactBoom, .impactMetal, .impactBreak,
             .impactPunch, .impactCinematic, .impactHit, .impactOther:
            return .impact
        case .foleyFootsteps, .foleyDoors, .foleyCloth, .foleyHands, .foleyObjects,
             .foleyKitchen, .foleyVehicles, .foleyWeapons, .foleyMovement, .foleyOther:
            return .foley
        case .voiceDialogue, .voiceShout, .voiceReaction, .voiceCrowd, .voiceCreature,
             .voiceChoir, .voiceChild, .voiceMale, .voiceFemale, .voiceOther:
            return .voice
        case .musicLoop, .musicStinger, .musicPiano, .musicStrings, .musicGuitar,
             .musicPercussion, .musicElectronic, .musicCinematic, .musicAmbient, .musicOther:
            return .music
        case .technologyClick, .technologyNotification, .technologyGlitch, .technologyComputer,
             .technologySciFi, .technologyGame, .technologyScan, .technologyPower, .technologyOther:
            return .technology
        }
    }

    var title: String {
        switch self {
        case .transitionRiser: return "上升与渐强"
        case .transitionDowner: return "下降与坠落"
        case .transitionPassBy: return "掠过与飞过"
        case .transitionReverse: return "反转与回吸"
        case .transitionSweep: return "扫频与切换"
        case .transitionWhoosh: return "基础呼啸"
        case .transitionOther: return "其他转场"
        case .ambienceWeather: return "天气与雷雨"
        case .ambienceWind: return "风与气流"
        case .ambienceWater: return "海洋与水流"
        case .ambienceNature: return "自然与野外"
        case .ambienceCity: return "城市与交通"
        case .ambienceInterior: return "室内与空间"
        case .ambienceCrowd: return "人群与公共场所"
        case .ambienceDark: return "悬疑与暗氛围"
        case .ambienceOther: return "其他环境"
        case .impactExplosion: return "爆炸与爆破"
        case .impactBoom: return "低频与轰鸣"
        case .impactMetal: return "金属撞击"
        case .impactBreak: return "破碎与残骸"
        case .impactPunch: return "猛击与拳击"
        case .impactCinematic: return "电影式重击"
        case .impactHit: return "基础冲击"
        case .impactOther: return "其他冲击"
        case .foleyFootsteps: return "脚步与奔跑"
        case .foleyDoors: return "门窗与门锁"
        case .foleyCloth: return "衣物与布料"
        case .foleyHands: return "手部与身体"
        case .foleyObjects: return "物品与道具"
        case .foleyKitchen: return "厨房与餐具"
        case .foleyVehicles: return "车辆与引擎"
        case .foleyWeapons: return "武器与刀枪"
        case .foleyMovement: return "动作与移动"
        case .foleyOther: return "其他拟音"
        case .voiceDialogue: return "对白与说话"
        case .voiceShout: return "喊叫与尖叫"
        case .voiceReaction: return "笑声与呼吸"
        case .voiceCrowd: return "欢呼与掌声"
        case .voiceCreature: return "怪物与生物"
        case .voiceChoir: return "吟唱与合唱"
        case .voiceChild: return "儿童与婴儿"
        case .voiceMale: return "男声"
        case .voiceFemale: return "女声"
        case .voiceOther: return "其他人声"
        case .musicLoop: return "循环与节奏段"
        case .musicStinger: return "片头与短乐句"
        case .musicPiano: return "钢琴与键盘"
        case .musicStrings: return "弦乐与管弦"
        case .musicGuitar: return "吉他与贝斯"
        case .musicPercussion: return "鼓与打击乐"
        case .musicElectronic: return "电子与合成器"
        case .musicCinematic: return "电影与史诗配乐"
        case .musicAmbient: return "氛围铺底"
        case .musicOther: return "其他音乐"
        case .technologyClick: return "点击与按钮"
        case .technologyNotification: return "通知与提示"
        case .technologyGlitch: return "故障与错误"
        case .technologyComputer: return "电脑与键盘"
        case .technologySciFi: return "科幻与未来"
        case .technologyGame: return "游戏与 HUD"
        case .technologyScan: return "扫描与雷达"
        case .technologyPower: return "启动与电源"
        case .technologyOther: return "其他科技"
        }
    }

    var systemImage: String {
        switch self {
        case .transitionRiser: return "arrow.up.right"
        case .transitionDowner: return "arrow.down.right"
        case .transitionPassBy: return "arrow.right"
        case .transitionReverse: return "arrow.uturn.backward"
        case .transitionSweep: return "waveform.path"
        case .transitionWhoosh, .transitionOther: return "wind"
        case .ambienceWeather: return "cloud.rain"
        case .ambienceWind: return "wind"
        case .ambienceWater: return "water.waves"
        case .ambienceNature: return "leaf"
        case .ambienceCity: return "building.2"
        case .ambienceInterior: return "house"
        case .ambienceCrowd: return "person.3"
        case .ambienceDark, .ambienceOther: return "moon.stars"
        case .impactExplosion: return "burst"
        case .impactBoom: return "speaker.wave.3"
        case .impactMetal: return "hammer"
        case .impactBreak: return "square.3.layers.3d.down.right"
        case .impactPunch, .impactHit, .impactOther: return "waveform.path.ecg"
        case .impactCinematic: return "film"
        case .foleyFootsteps: return "shoeprints.fill"
        case .foleyDoors: return "door.left.hand.open"
        case .foleyCloth: return "tshirt"
        case .foleyHands: return "hand.raised"
        case .foleyObjects, .foleyOther: return "shippingbox"
        case .foleyKitchen: return "fork.knife"
        case .foleyVehicles: return "car"
        case .foleyWeapons: return "scope"
        case .foleyMovement: return "figure.walk.motion"
        case .voiceDialogue: return "quote.bubble"
        case .voiceShout: return "mouth"
        case .voiceReaction: return "face.smiling"
        case .voiceCrowd: return "person.3"
        case .voiceCreature: return "pawprint"
        case .voiceChoir: return "music.mic"
        case .voiceChild: return "figure.and.child.holdinghands"
        case .voiceMale, .voiceFemale, .voiceOther: return "person.wave.2"
        case .musicLoop: return "repeat"
        case .musicStinger: return "sparkles"
        case .musicPiano: return "pianokeys"
        case .musicStrings: return "music.note.list"
        case .musicGuitar: return "guitars"
        case .musicPercussion: return "metronome"
        case .musicElectronic: return "waveform"
        case .musicCinematic: return "film.stack"
        case .musicAmbient, .musicOther: return "music.note"
        case .technologyClick: return "cursorarrow.click"
        case .technologyNotification: return "bell"
        case .technologyGlitch: return "bolt.trianglebadge.exclamationmark"
        case .technologyComputer: return "keyboard"
        case .technologySciFi: return "atom"
        case .technologyGame: return "gamecontroller"
        case .technologyScan: return "radar"
        case .technologyPower: return "power"
        case .technologyOther: return "cpu"
        }
    }

    fileprivate var keywords: [String] {
        switch self {
        case .transitionRiser: return ["riser", "rising", "rise", "uplifter", "上升", "渐强", "升调", "推进"]
        case .transitionDowner: return ["downer", "falling", "drop", "下降", "下坠", "坠落", "降调"]
        case .transitionPassBy: return ["pass by", "passby", "flyby", "fly by", "掠过", "飞过", "经过"]
        case .transitionReverse: return ["reverse", "reversed", "rewind", "倒放", "反转", "回吸", "回卷"]
        case .transitionSweep: return ["sweep", "swish", "wipe", "扫频", "扫描", "切换"]
        case .transitionWhoosh: return ["whoosh", "swoosh", "woosh", "whip", "呼啸", "嗖", "咻", "唰"]
        case .ambienceWeather: return ["weather", "rain", "thunder", "storm", "snow", "天气", "雨", "雷", "暴风", "雪"]
        case .ambienceWind: return ["wind", "breeze", "gust", "风", "微风", "阵风", "气流"]
        case .ambienceWater: return ["water", "ocean", "river", "waves", "sea", "stream", "水", "海", "河", "溪", "浪"]
        case .ambienceNature: return ["nature", "forest", "bird", "insect", "jungle", "field", "自然", "森林", "鸟", "虫", "田野"]
        case .ambienceCity: return ["city", "street", "traffic", "urban", "subway", "城市", "街道", "交通", "地铁"]
        case .ambienceInterior: return ["room", "interior", "indoor", "office", "home", "室内", "房间", "办公室", "家庭"]
        case .ambienceCrowd: return ["crowd", "cafe", "market", "public", "人群", "咖啡馆", "市场", "公共场所"]
        case .ambienceDark: return ["horror", "dark", "tension", "drone", "eerie", "恐怖", "悬疑", "阴森", "低鸣"]
        case .impactExplosion: return ["explosion", "blast", "bomb", "detonate", "爆炸", "爆破", "炸弹"]
        case .impactBoom: return ["boom", "sub", "bass", "rumble", "低频", "低音", "轰鸣", "隆隆"]
        case .impactMetal: return ["metal", "metallic", "anvil", "steel", "金属", "钢铁", "铁砧"]
        case .impactBreak: return ["debris", "break", "crash", "glass", "shatter", "碎裂", "破碎", "残骸", "玻璃"]
        case .impactPunch: return ["slam", "punch", "kick", "thump", "猛击", "拳击", "砰", "闷击"]
        case .impactCinematic: return ["cinematic", "trailer", "braam", "epic", "电影", "预告", "史诗"]
        case .impactHit: return ["impact", "hit", "strike", "冲击", "重击", "撞击"]
        case .foleyFootsteps: return ["footstep", "footsteps", "walking", "running", "shoe", "脚步", "走路", "跑步", "鞋"]
        case .foleyDoors: return ["door", "gate", "lock", "knock", "window", "门", "开门", "关门", "门锁", "敲门", "窗"]
        case .foleyCloth: return ["cloth", "fabric", "clothes", "衣物", "布料", "衣服", "摩擦"]
        case .foleyHands: return ["hands", "body", "clap", "snap", "finger", "手", "身体", "拍手", "响指", "手指"]
        case .foleyObjects: return ["object", "prop", "pickup", "put down", "物品", "道具", "拿起", "放下"]
        case .foleyKitchen: return ["kitchen", "dish", "cup", "plate", "cooking", "厨房", "碗", "杯", "盘", "烹饪"]
        case .foleyVehicles: return ["vehicle", "engine", "motor", "car", "bike", "汽车", "车辆", "引擎", "发动机", "自行车"]
        case .foleyWeapons: return ["weapon", "gun", "rifle", "sword", "knife", "枪", "武器", "剑", "刀"]
        case .foleyMovement: return ["movement", "action", "jump", "slide", "动作", "移动", "跳", "滑动"]
        case .voiceDialogue: return ["dialogue", "dialog", "speech", "talk", "talking", "chat", "conversation", "speak", "对白", "说话", "聊天", "交谈", "台词", "语音"]
        case .voiceShout: return ["shout", "scream", "yell", "cry", "喊", "尖叫", "哭", "咆哮"]
        case .voiceReaction: return ["laugh", "gasp", "sigh", "breath", "笑", "喘", "叹气", "呼吸"]
        case .voiceCrowd: return ["cheer", "applause", "crowd", "欢呼", "掌声", "喝彩"]
        case .voiceCreature: return ["monster", "creature", "zombie", "animal vocal", "怪物", "生物", "僵尸", "兽吼"]
        case .voiceChoir: return ["choir", "chant", "vocal", "吟唱", "合唱", "哼唱"]
        case .voiceChild: return ["child", "children", "kid", "baby", "儿童", "小孩", "婴儿"]
        case .voiceMale: return ["male", "man", "boy", "男声", "男人", "男孩"]
        case .voiceFemale: return ["female", "woman", "girl", "女声", "女人", "女孩"]
        case .musicLoop: return ["loop", "loopable", "循环", "循环段"]
        case .musicStinger: return ["stinger", "logo", "ident", "bumper", "片头", "片尾", "标志", "短乐句"]
        case .musicPiano: return ["piano", "keyboard music", "钢琴", "键盘乐"]
        case .musicStrings: return ["strings", "violin", "cello", "orchestra", "弦乐", "小提琴", "大提琴", "管弦"]
        case .musicGuitar: return ["guitar", "bass guitar", "吉他", "贝斯"]
        case .musicPercussion: return ["drum", "percussion", "beat", "rhythm", "鼓", "打击乐", "节奏"]
        case .musicElectronic: return ["synth", "electronic", "edm", "电子", "合成器"]
        case .musicCinematic: return ["cinematic", "score", "trailer", "epic", "电影", "配乐", "预告", "史诗"]
        case .musicAmbient: return ["ambient", "pad", "drone", "氛围音乐", "铺底", "长音"]
        case .technologyClick: return ["click", "tap", "button", "mouse", "点击", "按键", "按钮", "鼠标"]
        case .technologyNotification: return ["notification", "alert", "message", "ping", "提示", "通知", "消息", "叮"]
        case .technologyGlitch: return ["glitch", "error", "distort", "failure", "故障", "错误", "失真", "失败"]
        case .technologyComputer: return ["computer", "keyboard", "typing", "digital", "电脑", "键盘", "打字", "数码"]
        case .technologySciFi: return ["sci fi", "scifi", "futuristic", "laser", "robot", "科幻", "未来", "激光", "机器人"]
        case .technologyGame: return ["game", "hud", "menu", "游戏", "界面", "菜单"]
        case .technologyScan: return ["scan", "scanner", "radar", "data", "扫描", "雷达", "数据"]
        case .technologyPower: return ["power", "activate", "startup", "shutdown", "电源", "启动", "关闭", "激活"]
        case .transitionOther, .ambienceOther, .impactOther, .foleyOther,
             .voiceOther, .musicOther, .technologyOther:
            return []
        }
    }

    var isFallback: Bool { keywords.isEmpty }

    func matches(_ item: SoundItem) -> Bool {
        SmartTaxonomy.classify(item).details[parent] == self
    }

    static let groupedByParent = Dictionary(grouping: allCases, by: \.parent)

    static func bestMatch(in parent: SmartCollection, normalizedText: String) -> Self? {
        SmartTaxonomy.classify(normalizedText: normalizedText).details[parent]
    }
}

enum SmartDurationBand: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case unknown, instant, veryShort, short, medium, longForm, extended

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unknown: return "时长未知"
        case .instant: return "瞬时 · 0–2 秒"
        case .veryShort: return "极短 · 2–5 秒"
        case .short: return "短 · 5–10 秒"
        case .medium: return "中等 · 10–20 秒"
        case .longForm: return "长 · 20–45 秒"
        case .extended: return "超长 · 45 秒以上"
        }
    }

    var systemImage: String {
        switch self {
        case .unknown: return "questionmark"
        case .instant: return "bolt.fill"
        case .veryShort: return "hare.fill"
        case .short: return "timer"
        case .medium: return "clock"
        case .longForm: return "clock.badge"
        case .extended: return "infinity"
        }
    }

    static func band(for duration: Double) -> Self {
        guard duration > 0 else { return .unknown }
        switch duration {
        case ..<2: return .instant
        case ..<5: return .veryShort
        case ..<10: return .short
        case ..<20: return .medium
        case ..<45: return .longForm
        default: return .extended
        }
    }
}

struct SmartLeafCollection: Codable, Identifiable, Hashable, Sendable {
    let detail: SmartSubcollection
    let durationBand: SmartDurationBand

    var id: String { "\(detail.rawValue).\(durationBand.rawValue)" }
    var title: String { durationBand.title }
    var systemImage: String { durationBand.systemImage }

    func matches(_ item: SoundItem) -> Bool {
        SmartTaxonomy.classify(item).details[detail.parent] == detail
            && SmartDurationBand.band(for: item.duration) == durationBand
    }

    static func all(for detail: SmartSubcollection) -> [Self] {
        SmartDurationBand.allCases.map { Self(detail: detail, durationBand: $0) }
    }
}

extension SmartCollection {
    static let categorizedCases = allCases.filter { $0 != .untagged }

    var title: String {
        switch self {
        case .transition: return "转场与呼啸"
        case .ambience: return "环境与氛围"
        case .impact: return "冲击与重击"
        case .foley: return "拟音与动作"
        case .voice: return "人声与对白"
        case .music: return "音乐与旋律"
        case .technology: return "科技与界面"
        case .untagged: return "未识别"
        }
    }

    var systemImage: String {
        switch self {
        case .transition: return "wind"
        case .ambience: return "moon.stars.fill"
        case .impact: return "burst.fill"
        case .foley: return "shoeprints.fill"
        case .voice: return "person.wave.2.fill"
        case .music: return "music.note"
        case .technology: return "cpu.fill"
        case .untagged: return "questionmark.folder.fill"
        }
    }

    var shortTag: String {
        switch self {
        case .transition: return "转场"
        case .ambience: return "环境"
        case .impact: return "冲击"
        case .foley: return "拟音"
        case .voice: return "人声"
        case .music: return "音乐"
        case .technology: return "科技"
        case .untagged: return "未识别"
        }
    }

    var children: [SmartSubcollection] { SmartSubcollection.groupedByParent[self] ?? [] }

    fileprivate var rootKeywords: [String] {
        switch self {
        case .transition: return ["transition", "trans", "转场"]
        case .ambience: return ["ambience", "ambient", "atmo", "环境", "氛围"]
        case .impact: return ["impact", "冲击", "重击"]
        case .foley: return ["foley", "拟音"]
        case .voice: return ["voice", "vocal", "人声"]
        case .music: return ["music", "melody", "score", "音乐", "旋律", "配乐", "乐器"]
        case .technology: return ["technology", "tech", "界面", "科技"]
        case .untagged: return []
        }
    }

    func matches(_ item: SoundItem) -> Bool { matches(normalizedText: item.smartClassificationText) }

    func matches(normalizedText text: String) -> Bool {
        let result = SmartTaxonomy.classify(normalizedText: text)
        return self == .untagged ? result.parents.isEmpty : result.parents.contains(self)
    }

    static func primaryMatches(normalizedText text: String) -> [Self] {
        SmartTaxonomy.classify(normalizedText: text).parents
    }
}

struct SmartTaxonomyClassification: Sendable {
    let parents: [SmartCollection]
    let details: [SmartCollection: SmartSubcollection]
}

enum SmartTaxonomyCachePolicy {
    static let maximumClassificationEntries = 50_000
    static let maximumEstimatedClassificationBytes = 24 * 1_024 * 1_024

    static func estimatedCost(
        key: NSString,
        classification: SmartTaxonomyClassification
    ) -> Int {
        128
            + key.lengthOfBytes(using: String.Encoding.utf8.rawValue)
            + classification.parents.count * 16
            + classification.details.count * 32
    }
}

/// A classification snapshot shared by the sidebar and result builder. Building this once
/// per classification revision avoids re-running the taxonomy matcher every time the user
/// opens a different smart collection in a large local library.
struct SmartTaxonomyIndex: Sendable {
    let parentIDs: [SmartCollection: Set<UUID>]
    let detailIDs: [SmartSubcollection: Set<UUID>]
    let leafIDs: [SmartLeafCollection: Set<UUID>]
    let unknownDurationIDs: [SmartDurationBand: Set<UUID>]
    let parentCounts: [SmartCollection: Int]
    let detailCounts: [SmartSubcollection: Int]
    let leafCounts: [SmartLeafCollection: Int]
    let unknownDurationCounts: [SmartDurationBand: Int]

    func contains(_ itemID: UUID, in collection: SmartCollection) -> Bool {
        parentIDs[collection]?.contains(itemID) == true
    }

    func contains(_ itemID: UUID, in detail: SmartSubcollection) -> Bool {
        detailIDs[detail]?.contains(itemID) == true
    }

    func contains(_ itemID: UUID, in leaf: SmartLeafCollection) -> Bool {
        leafIDs[leaf]?.contains(itemID) == true
    }

    func contains(_ itemID: UUID, in durationBand: SmartDurationBand) -> Bool {
        unknownDurationIDs[durationBand]?.contains(itemID) == true
    }
}

/// One Aho–Corasick pass finds every category keyword. This changes classification
/// from roughly `sounds × categories × keywords` substring checks to linear work in
/// the total filename/path length, which matters for 30k–100k item libraries.
enum SmartTaxonomy {
    static func classify(_ item: SoundItem) -> SmartTaxonomyClassification {
        let key = cacheKey(for: item)
        if let cached = classificationCache.object(forKey: key) {
            return cached.value
        }
        let result = classify(normalizedText: item.smartClassificationText)
        classificationCache.setObject(
            SmartClassificationBox(result),
            forKey: key,
            cost: SmartTaxonomyCachePolicy.estimatedCost(key: key, classification: result)
        )
        return result
    }

    static func classify(normalizedText text: String) -> SmartTaxonomyClassification {
        let matchedTargets = matcher.matches(in: text)
        var parentSet = Set<SmartCollection>()
        var detailSet = Set<SmartSubcollection>()

        for target in matchedTargets {
            switch target {
            case let .parent(parent):
                parentSet.insert(parent)
            case let .detail(detail):
                detailSet.insert(detail)
                parentSet.insert(detail.parent)
            }
        }

        let parents = SmartCollection.categorizedCases.filter(parentSet.contains)
        var details: [SmartCollection: SmartSubcollection] = [:]
        details.reserveCapacity(parents.count)
        for parent in parents {
            let children = parent.children
            details[parent] = children.first { !$0.isFallback && detailSet.contains($0) }
                ?? children.first(where: \.isFallback)
        }
        return SmartTaxonomyClassification(parents: parents, details: details)
    }

    private static let matcher: SmartKeywordMatcher = {
        var patterns: [(String, SmartKeywordTarget)] = []
        for parent in SmartCollection.categorizedCases {
            patterns.append(contentsOf: parent.rootKeywords.map { ($0, .parent(parent)) })
        }
        for detail in SmartSubcollection.allCases where !detail.isFallback {
            patterns.append(contentsOf: detail.keywords.map { ($0, .detail(detail)) })
        }
        return SmartKeywordMatcher(patterns: patterns)
    }()

    private static let classificationCache: NSCache<NSString, SmartClassificationBox> = {
        let cache = NSCache<NSString, SmartClassificationBox>()
        cache.countLimit = SmartTaxonomyCachePolicy.maximumClassificationEntries
        cache.totalCostLimit = SmartTaxonomyCachePolicy.maximumEstimatedClassificationBytes
        return cache
    }()

    private static let indexCache: NSCache<NSString, SmartTaxonomyIndexBox> = {
        let cache = NSCache<NSString, SmartTaxonomyIndexBox>()
        // A classification revision makes every earlier membership snapshot obsolete. Keeping
        // three generations can retain several full UUID-set indexes after repeated tag edits;
        // one generation is enough because an in-flight caller keeps its returned value alive.
        cache.countLimit = 1
        return cache
    }()

    static func index(for packs: [SoundPack], revision: UInt64) -> SmartTaxonomyIndex {
        let cacheKey = indexCacheKey(for: packs, revision: revision)
        if let cached = indexCache.object(forKey: cacheKey) {
            return cached.value
        }

        var parentIDs = Dictionary(
            uniqueKeysWithValues: SmartCollection.allCases.map { ($0, Set<UUID>()) }
        )
        var detailIDs = Dictionary(
            uniqueKeysWithValues: SmartSubcollection.allCases.map { ($0, Set<UUID>()) }
        )
        var leafIDs: [SmartLeafCollection: Set<UUID>] = [:]
        var unknownDurationIDs = Dictionary(
            uniqueKeysWithValues: SmartDurationBand.allCases.map { ($0, Set<UUID>()) }
        )

        for pack in packs {
            for item in pack.items {
                let classification = classify(item)
                if classification.parents.isEmpty {
                    parentIDs[.untagged, default: []].insert(item.id)
                    unknownDurationIDs[SmartDurationBand.band(for: item.duration), default: []]
                        .insert(item.id)
                    continue
                }

                for parent in classification.parents {
                    parentIDs[parent, default: []].insert(item.id)
                    if let detail = classification.details[parent] {
                        detailIDs[detail, default: []].insert(item.id)
                        let leaf = SmartLeafCollection(
                            detail: detail,
                            durationBand: SmartDurationBand.band(for: item.duration)
                        )
                        leafIDs[leaf, default: []].insert(item.id)
                    }
                }
            }
        }

        let index = SmartTaxonomyIndex(
            parentIDs: parentIDs,
            detailIDs: detailIDs,
            leafIDs: leafIDs,
            unknownDurationIDs: unknownDurationIDs,
            parentCounts: parentIDs.mapValues(\.count),
            detailCounts: detailIDs.mapValues(\.count),
            leafCounts: leafIDs.mapValues(\.count),
            unknownDurationCounts: unknownDurationIDs.mapValues(\.count)
        )
        indexCache.setObject(SmartTaxonomyIndexBox(index), forKey: cacheKey)
        return index
    }

    private static func indexCacheKey(for packs: [SoundPack], revision: UInt64) -> NSString {
        var hasher = Hasher()
        hasher.combine(revision)
        for pack in packs.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            hasher.combine(pack.id)
            hasher.combine(pack.rootPath)
            hasher.combine(pack.items.count)
            hasher.combine(pack.lastScannedAt.timeIntervalSinceReferenceDate)
        }
        return "\(revision):\(hasher.finalize())" as NSString
    }

    private static func cacheKey(for item: SoundItem) -> NSString {
        var hasher = Hasher()
        // Classification depends on the source naming context as well as on
        // user metadata. Include the relative path so a confirmed rename or
        // move cannot reuse a stale category from the previous filename.
        hasher.combine(item.relativePath)
        hasher.combine(item.fileExtension)
        hasher.combine(item.customName)
        hasher.combine(item.tags)
        return "\(item.id.uuidString):\(hasher.finalize())" as NSString
    }
}

private final class SmartClassificationBox: NSObject {
    let value: SmartTaxonomyClassification

    init(_ value: SmartTaxonomyClassification) {
        self.value = value
    }
}

private final class SmartTaxonomyIndexBox: NSObject {
    let value: SmartTaxonomyIndex

    init(_ value: SmartTaxonomyIndex) {
        self.value = value
    }
}

private enum SmartKeywordTarget: Hashable {
    case parent(SmartCollection)
    case detail(SmartSubcollection)
}

private struct SmartKeywordMatcher {
    private struct Node {
        var transitions: [Unicode.Scalar: Int] = [:]
        var failure = 0
        var outputs = Set<SmartKeywordTarget>()
    }

    private let nodes: [Node]

    init(patterns: [(String, SmartKeywordTarget)]) {
        var nodes = [Node()]

        for (rawPattern, target) in patterns {
            let pattern = Self.searchPattern(for: rawPattern)
            guard !pattern.isEmpty else { continue }
            var state = 0
            for scalar in pattern.unicodeScalars {
                if let next = nodes[state].transitions[scalar] {
                    state = next
                } else {
                    let next = nodes.count
                    nodes.append(Node())
                    nodes[state].transitions[scalar] = next
                    state = next
                }
            }
            nodes[state].outputs.insert(target)
        }

        var queue: [Int] = []
        queue.reserveCapacity(nodes.count)
        for child in nodes[0].transitions.values {
            nodes[child].failure = 0
            queue.append(child)
        }

        var cursor = 0
        while cursor < queue.count {
            let state = queue[cursor]
            cursor += 1
            for (scalar, next) in nodes[state].transitions {
                queue.append(next)
                var fallback = nodes[state].failure
                while fallback != 0 && nodes[fallback].transitions[scalar] == nil {
                    fallback = nodes[fallback].failure
                }
                if let candidate = nodes[fallback].transitions[scalar], candidate != next {
                    nodes[next].failure = candidate
                } else {
                    nodes[next].failure = 0
                }
                nodes[next].outputs.formUnion(nodes[nodes[next].failure].outputs)
            }
        }

        self.nodes = nodes
    }

    func matches(in text: String) -> Set<SmartKeywordTarget> {
        var state = 0
        var result = Set<SmartKeywordTarget>()
        for scalar in text.unicodeScalars {
            while state != 0 && nodes[state].transitions[scalar] == nil {
                state = nodes[state].failure
            }
            state = nodes[state].transitions[scalar] ?? 0
            if !nodes[state].outputs.isEmpty {
                result.formUnion(nodes[state].outputs)
            }
        }
        return result
    }

    private static func searchPattern(for keyword: String) -> String {
        let value = keyword.lowercased()
        let isShortLatinToken = value.utf8.count <= 3
            && value.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.letters.contains($0) }
        return isShortLatinToken ? " \(value) " : value
    }
}

extension SoundItem {
    /// Lowercase, separator-normalized text makes short tokens such as "UI" and "hit"
    /// precise and is substantially cheaper than dozens of localized comparisons.
    var smartClassificationText: String {
        let folded = searchableText
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        var result = " "
        result.reserveCapacity(folded.utf8.count + 2)
        var hasTrailingSpace = true
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                hasTrailingSpace = false
            } else if !hasTrailingSpace {
                result.append(" ")
                hasTrailingSpace = true
            }
        }
        if !hasTrailingSpace { result.append(" ") }
        return result
    }
}
