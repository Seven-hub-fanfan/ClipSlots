import AppKit
import SwiftUI
import ClipSlotsKit

/// 画布节点正文的字体目录与解析（v2.11.7 hotfix19）。
///
/// ## 为什么不能直接 `Font.custom(族名, size:)`
///
/// `Font.custom` 底层等价于 `NSFont(name:size:)`，而后者要的是**字体名 / PostScript 名**
/// （`HarmonyOSSansSC-Regular`），不是用户在字体册里看到的**族名**（`HarmonyOS Sans SC`）。
/// 中文字体的族名与 PostScript 名几乎从不相同，于是 `Font.custom("HarmonyOS Sans SC", size:)`
/// 会**静默返回系统字体** —— 没有崩溃、没有告警、没有任何日志，表现就是「选了字体但一点变化都没有」。
/// 这正是本次要修的那个 bug 的类别：所以这里必须自己做「族名 → 可用字体」的解析，并且解析失败时
/// 明确回落到系统字体（而不是假装成功）。
///
/// ## 缓存
///
/// 卡片 body 每次求值都会问一次字体，画布上可能有几十张卡片。`availableMembers(ofFontFamily:)`
/// 每次都要走一遍字体注册表，不能放在渲染路径上裸调 —— 故按 `族名::字号` 记忆化。
enum CanvasFontCatalog {

    /// 「常用」分组的**期望**顺序。只有本机真的装了的才会出现在 picker 里 ——
    /// 列一堆装不上的字体，用户选了却没效果，等于把刚修掉的 bug 又造回去。
    private static let preferredFamilies: [String] = [
        // 中文无衬线（系统自带 / 常见第三方）
        "PingFang SC", "HarmonyOS Sans SC", "MiSans", "OPPOSans", "Source Han Sans SC",
        "Noto Sans SC", "Heiti SC", "Hiragino Sans GB",
        // 中文衬线 / 楷体
        "Songti SC", "STSong", "Kaiti SC", "STKaiti", "Yuanti SC",
        // 西文
        "SF Pro", "SF Pro Text", "Helvetica Neue", "Avenir Next", "Georgia", "Times New Roman",
        // 等宽（prompt 里常混代码 / 变量占位符）
        "SF Mono", "Menlo", "Monaco", "JetBrains Mono", "Fira Code", "Sarasa Mono SC"
    ]

    /// 本机全部可用族名。
    ///
    /// 过滤掉 `.` 开头的族：那是系统私有族（`.AppleSystemUIFont` 之类），选中后行为不可预期，
    /// 而且在 picker 里显示成一串下划线开头的乱名。
    static let allFamilies: [String] = {
        NSFontManager.shared.availableFontFamilies
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }()

    private static let availableSet: Set<String> = Set(allFamilies)

    /// 常用分组（已按 `preferredFamilies` 的顺序，且只留本机装了的）。
    static let commonFamilies: [String] = preferredFamilies.filter { availableSet.contains($0) }

    /// 「其他全部字体」分组：全量减去已在常用分组里出现过的，避免同一项在菜单里出现两次。
    static let otherFamilies: [String] = {
        let common = Set(commonFamilies)
        return allFamilies.filter { !common.contains($0) }
    }()

    static func isAvailable(_ family: String) -> Bool { availableSet.contains(family) }

    /// picker 上显示的名字。字体被卸载后仍显示原族名 + 「（缺失）」，而不是悄悄变成「跟随系统」——
    /// 用户得知道是字体没了，不是自己的设置丢了。
    static func displayName(_ family: String?) -> String {
        guard let family, !family.isEmpty else { return "跟随系统" }
        return isAvailable(family) ? family : "\(family)（缺失）"
    }

    // MARK: - 解析

    private static let cache: NSCache<NSString, NSFont> = {
        let c = NSCache<NSString, NSFont>()
        c.countLimit = 256
        return c
    }()

    /// 族名 → NSFont。解析不到一律回落系统字体（绝不返回 nil 让调用方自己猜）。
    static func nsFont(family: String?, size: CGFloat) -> NSFont {
        let clamped = CanvasNode.clampBodyFontSize(size)
        guard let family, !family.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .systemFont(ofSize: clamped)
        }
        let key = "\(family)::\(clamped)" as NSString
        if let hit = cache.object(forKey: key) { return hit }

        let resolved = resolve(family: family, size: clamped)
        cache.setObject(resolved, forKey: key)
        return resolved
    }

    static func font(family: String?, size: CGFloat) -> Font {
        Font(nsFont(family: family, size: size))
    }

    /// 三级解析，逐级放宽：
    ///   1. 直接当字体名试（用户可能存的就是 PostScript 名，或该族恰好同名）。
    ///   2. 族 → 成员列表，挑**常规字重**那一支（不是无脑取第一个：不少中文族第一个成员是 Light
    ///      或 Bold，直接取会让"选了个字体，结果整段变细/变粗"）。
    ///   3. 用 `NSFontDescriptor` 的族属性兜底（能覆盖某些没有规范成员表的族）。
    private static func resolve(family: String, size: CGFloat) -> NSFont {
        if let direct = NSFont(name: family, size: size) { return direct }

        if let members = NSFontManager.shared.availableMembers(ofFontFamily: family), !members.isEmpty {
            // 成员结构：[PostScript 名, 样式名, 字重(0~15), traits 位掩码]
            let regular = members.min { lhs, rhs in
                weightDistance(lhs) < weightDistance(rhs)
            }
            if let psName = (regular?.first as? String) ?? (members.first?.first as? String),
               let font = NSFont(name: psName, size: size) {
                return font
            }
        }

        let descriptor = NSFontDescriptor(fontAttributes: [.family: family])
        if let font = NSFont(descriptor: descriptor, size: size) { return font }

        return .systemFont(ofSize: size)
    }

    /// 与「常规字重 + 无斜体」的距离。越小越像 Regular。
    private static func weightDistance(_ member: [Any]) -> Int {
        let weight = (member.count > 2 ? member[2] as? Int : nil) ?? 5
        let traits = (member.count > 3 ? member[3] as? UInt : nil) ?? 0
        let mask = NSFontTraitMask(rawValue: traits)
        var penalty = abs(weight - 5)
        if mask.contains(.italicFontMask) { penalty += 20 }
        if mask.contains(.boldFontMask) { penalty += 10 }
        if mask.contains(.condensedFontMask) || mask.contains(.expandedFontMask) { penalty += 5 }
        return penalty
    }
}
