import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// AGT-26 S6 视觉规范。参考 ChatGPT / Claude / Happy 的手机端：整体单色，颜色只用来表达状态。
/// 数字来自 Happy 源码（HappyLayout/Tokens）和 ChatGPT iOS 的公开逆向规格。
enum Theme {
    /// 用户气泡：浅灰底、正文色文字（ChatGPT #F4F4F5 / 暗色 #2A2A2C），不用实心蓝
    static let userBubble = dynamic(light: 0xF4F4F5, dark: 0x2A2A2C)
    /// 卡片/输入框底色
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x1C1C1E)
    static let page = dynamic(light: 0xFFFFFF, dark: 0x000000)
    /// 主按钮：黑底（暗色模式白底），对应 ChatGPT/Happy 的发送圆钮
    static let ink = dynamic(light: 0x1D1D1F, dark: 0xFFFFFF)

    /// 状态色：只有这四种（Happy 的状态点）
    static let needsYou = Color(hex: 0xFF9500)
    static let running = Color(hex: 0x007AFF)
    static let done = Color(hex: 0x34C759)
    static let idle = Color(hex: 0x999999)

    static func statusColor(_ s: HarnessMember.Status) -> Color? {
        switch s {
        case .needsYou: return needsYou
        case .running: return running
        case .done: return done
        case .idle: return idle
        case .unknown: return nil
        }
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
#if canImport(UIKit)
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
#else
        Color(hex: light)
#endif
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

#if canImport(UIKit)
extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
#endif

/// 线程的 harness 图标：Codex 用终端、Claude 用星芒、ChatGPT 用对话气泡（只用系统符号，不用品牌图）
extension HarnessMember {
    var symbol: String {
        if role == .subagent { return "arrow.turn.down.right" }
        switch kind {
        case "codex": return "terminal"
        case "claude": return "sparkle"
        case "chatgpt": return "bubble.left"
        default: return "circle.dashed"
        }
    }
}

/// 触感只响应用户自己的操作（Happy Haptics.swift）：展开/折叠 light，打开抽屉 soft
enum Haptics {
    static func light() {
#if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
#endif
    }
    static func soft() {
#if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
#endif
    }
}

/// 图标右下角带状态点（Happy 会话行的做法）
struct StatusIcon: View {
    let member: HarnessMember
    var body: some View {
        Image(systemName: member.symbol)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 30, height: 30)
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
            .overlay(alignment: .bottomTrailing) {
                if let c = Theme.statusColor(member.status) {
                    Circle().fill(c).frame(width: 9, height: 9)
                        .overlay(Circle().stroke(Theme.page, lineWidth: 2))
                        .offset(x: 2, y: 2)
                }
            }
            .accessibilityHidden(true)
    }
}
