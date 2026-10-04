//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import Foundation

/// Selects the equal-brightness mapping path while preserving legacy synchronization fallback.
/// 在保留旧同步回退路径的前提下选择等亮度映射路径。
final class EqualBrightnessSyncCoordinator {
  static let shared = EqualBrightnessSyncCoordinator()

  /// Creates the process-wide coordinator used by the existing brightness job.
  /// 创建供现有亮度任务使用的进程级协调器。
  private init() {}

  /// Allows only the configured reference display to start mapped synchronization.
  /// 只允许配置的参考显示器启动映射同步。
  func shouldPropagate(sourceDisplay: Display) -> Bool {
    let store = EqualBrightnessSettingsStore.shared
    return !store.isEnabled() || store.isReferenceDisplay(sourceDisplay)
  }

  /// Computes a target value from a curve or falls back to the legacy delta rule.
  /// 使用曲线计算目标值；不满足映射条件时回退到原有增量规则。
  func targetValue(for targetDisplay: Display, sourceDisplay: Display, delta: Float) -> Float {
    let store = EqualBrightnessSettingsStore.shared
    guard store.isEnabled(), store.isReferenceDisplay(sourceDisplay), targetDisplay != sourceDisplay else {
      return Self.clamp(targetDisplay.getBrightness() + delta)
    }
    let curve = store.curve(for: targetDisplay) ?? EqualBrightnessCurve(kind: .linear, points: [])
    let mappedValue = curve.value(at: Double(sourceDisplay.getBrightness()))
    return Float(EqualBrightnessCurve.clamp(mappedValue))
  }

  /// Keeps runtime brightness values inside the same normalized range as Display.
  /// 将运行时亮度值限制在 Display 使用的归一化范围内。
  private static func clamp(_ value: Float) -> Float {
    guard value.isFinite else {
      return 0
    }
    return max(0, min(1, value))
  }
}
