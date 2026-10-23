import Foundation
import CoreGraphics

/// 画布媒体节点上的**媒体元信息**及其显示文案（v2.15.0）。
///
/// ## 它解决什么
///
/// 用户要求媒体节点上能看到"尺寸等"信息。这句要求听起来只是"加一行小字"，但真正麻烦的是
/// **同一份事实有很多种写法**，而写法不一致会让用户以为自己看到的是不同的东西：
/// `1024x1024` / `1024×1024` / `1024*1024`、`1:1` / `1.0` / `方形`、`8s` / `0:08` / `8.0 秒`。
/// 画布上一屏十几个节点，三种写法混在一起就不再是"信息"而是噪声。
///
/// 所以格式化被整个搬到 Kit 层的纯函数里：视图只负责拼版，"该写成什么样"只有一个答案，
/// 而且这个答案能被 smoke 断言逐条钉住（`CANVAS-MEDIA-*`）。
///
/// ## 为什么比例要"贴档"而不是老老实实约分
///
/// 真实出图结果的像素几乎从不是标准比例：`1024×576` 约分是 `16:9`（干净），但
/// `1360×768` 约分出来是 `85:48` —— 技术上完全正确，对人类完全没用。用户脑子里的档位表就是
/// `1:1 / 4:3 / 16:9 / 9:16 / 3:2 …` 那十几个，所以先按**相对容差贴档**，贴不上才约分，
/// 约分出来的分子分母过大（> `ratioMaxTerm`）就退成一位小数的 `1.77:1`。
///
/// 容差取 1.5%：`1360×768`(1.7708) 与 16:9(1.7778) 差 0.39%，该贴上；
/// 而 3:2(1.5) 与 16:9 之间差了 18%，不可能误贴。
public enum CanvasMediaInfo {

    // MARK: - 常量

    /// 贴档容差（相对误差）。见类型注释。
    public static let ratioTolerance: CGFloat = 0.015

    /// 约分结果允许的最大项。超过就说明"约分出来的比例人类读不懂"，退成小数写法。
    public static let ratioMaxTerm: Int = 40

    /// 人类真正会念的比例档位。顺序无所谓（匹配取最近），但**必须成对出现**（横/竖）：
    /// 只放 `16:9` 会让 `576×1024` 贴不上档，退化成 `9:16` 本该有的那个干净答案的小数形式。
    public static let commonRatios: [(w: Int, h: Int)] = [
        (1, 1),
        (4, 3), (3, 4),
        (3, 2), (2, 3),
        (16, 9), (9, 16),
        (5, 4), (4, 5),
        (2, 1), (1, 2),
        (21, 9), (9, 21),
        (16, 10), (10, 16),
        (7, 5), (5, 7),
    ]

    // MARK: - 尺寸

    /// `1024×1024`。用 `×`（U+00D7）而不是字母 `x`：后者在等宽数字旁边会被当成变量名读，
    /// 而且不同字体下高度对不齐，一行小字里非常显眼。
    ///
    /// 非正尺寸返回 nil —— "0×0" 不是信息，是"我没读到"，那种情况下整个角标都不该出现。
    public static func sizeLabel(_ size: CGSize) -> String? {
        let w = Int(size.width.rounded())
        let h = Int(size.height.rounded())
        guard w > 0, h > 0 else { return nil }
        return "\(w)×\(h)"
    }

    // MARK: - 比例

    /// `16:9` / `1:1` / `1.37:1`。推导见类型注释。
    public static func ratioLabel(_ size: CGSize) -> String? {
        let w = size.width
        let h = size.height
        guard w > 0, h > 0 else { return nil }
        let value = w / h

        // 1) 贴档。
        var best: (w: Int, h: Int, error: CGFloat)?
        for candidate in commonRatios {
            let target = CGFloat(candidate.w) / CGFloat(candidate.h)
            let error = abs(value - target) / target
            if error <= ratioTolerance, best == nil || error < best!.error {
                best = (candidate.w, candidate.h, error)
            }
        }
        if let best { return "\(best.w):\(best.h)" }

        // 2) 约分。只在像素本来就是整数时有意义（非整数的"尺寸"来自比例字符串解析，走不到这里）。
        let iw = Int(w.rounded())
        let ih = Int(h.rounded())
        if iw > 0, ih > 0, abs(w - CGFloat(iw)) < 0.01, abs(h - CGFloat(ih)) < 0.01 {
            let g = gcd(iw, ih)
            let rw = iw / g
            let rh = ih / g
            if rw <= ratioMaxTerm && rh <= ratioMaxTerm { return "\(rw):\(rh)" }
        }

        // 3) 小数兜底。长边在前，保证读出来永远是"几比一"而不是"零点几比一"。
        if value >= 1 {
            return "\(decimal2(value)):1"
        } else {
            return "1:\(decimal2(1 / value))"
        }
    }

    /// 最大公约数。`gcd(x, 0) == x`，调用方已保证两者为正。
    static func gcd(_ a: Int, _ b: Int) -> Int {
        var x = abs(a)
        var y = abs(b)
        while y != 0 { (x, y) = (y, x % y) }
        return max(1, x)
    }

    /// 两位有效的小数写法：整数就不带小数点（`2:1` 而不是 `2.00:1`）。
    static func decimal2(_ v: CGFloat) -> String {
        let rounded = (v * 100).rounded() / 100
        if abs(rounded - rounded.rounded()) < 0.005 {
            return String(Int(rounded.rounded()))
        }
        return String(format: "%.2f", Double(rounded))
    }

    // MARK: - 时长

    /// `0:08` / `1:05` / `12:03` / `1:02:03`。
    ///
    /// 为什么用"钟表写法"而不是 `8s`：视频节点旁边紧挨着的是分辨率 `1024×576`，两个都是纯数字时
    /// `8s` 那个 `s` 是唯一的区分标记，一眼扫过去容易读成尺寸的一部分。冒号是时间的普适记号。
    ///
    /// 负数 / NaN / 无穷返回 nil：这些值只能来自读取失败，显示 `0:00` 会被当成"这是个零长度视频"。
    public static func durationLabel(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        let total = Int(seconds.rounded())
        let s = total % 60
        let m = (total / 60) % 60
        let h = total / 3600
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - 体积

    /// `912 KB` / `2.4 MB` / `1.1 GB`。
    ///
    /// 刻意**不用** `ByteCountFormatter`：它跟随系统语言与十进制/二进制设置，同一个文件在不同机器上
    /// 能显示成 `2.4 MB` 或 `2.3 MB`，而这行小字的用途是"和别的节点比大小"，口径必须固定。
    /// 这里统一 1024 进制、≥10 时取整（`24 MB` 比 `24.3 MB` 好读且不丢信息）。
    public static func byteLabel(_ bytes: Int64) -> String? {
        guard bytes > 0 else { return nil }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var idx = 0
        while value >= 1024, idx < units.count - 1 {
            value /= 1024
            idx += 1
        }
        if idx == 0 { return "\(Int(value)) B" }
        if value >= 10 { return "\(Int(value.rounded())) \(units[idx])" }
        return String(format: "%.1f %@", value, units[idx])
    }

    // MARK: - 格式

    /// 文件后缀 → 大写格式名（`PNG` / `MP4`）。无后缀返回 nil。
    public static func formatLabel(fileName: String) -> String? {
        let ext = (fileName as NSString).pathExtension
        guard !ext.isEmpty, ext.count <= 5 else { return nil }
        return ext.uppercased()
    }

    // MARK: - 角标整行

    /// 用 ` · ` 连接非空片段。
    ///
    /// 空片段必须在这里被滤掉而不是靠调用方判断：角标的片段来源各自可能缺失（读不到尺寸、
    /// 图片没有时长），调用方每次都写一遍 `if let` 的结果是迟早漏一个，屏幕上出现
    /// `1024×1024 ·  · PNG` 这种前后不对称的空档。
    public static func badgeLine(_ parts: [String?]) -> String {
        parts.compactMap { part -> String? in
            guard let part, !part.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return part
        }.joined(separator: " · ")
    }

    // MARK: - 比例字符串 → 尺寸

    /// 把节点参数里的比例字符串（`"16:9"`）解析成一个用于占位的 `CGSize`。
    ///
    /// 用途：媒体节点**还没有产物**时，空态占位框仍然应该按用户选的比例画 —— 否则用户选了 `9:16`
    /// 却看到一个横的空框，会以为参数没生效。解析失败返回 nil，由调用方退成方形。
    public static func size(fromRatioString raw: String) -> CGSize? {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: true)
        guard parts.count == 2,
              let w = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let h = Double(parts[1].trimmingCharacters(in: .whitespaces)),
              w > 0, h > 0 else { return nil }
        return CGSize(width: w, height: h)
    }
}
