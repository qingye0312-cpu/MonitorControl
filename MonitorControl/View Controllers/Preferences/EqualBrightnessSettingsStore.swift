//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import Cocoa
import Foundation

/// Identifies a display with stable hardware values when available, or a local ID fallback.
/// 优先使用稳定硬件字段标识显示器；硬件信息不足时回退到当前连接的显示器 ID。
struct EqualBrightnessDisplayIdentity: Codable, Hashable {
  let key: String
  let displayName: String

  /// Builds a stable identity from the current display metadata.
  /// 根据当前显示器元数据构造稳定身份。
  init(display: Display) {
    self.displayName = display.name
    let normalizedName = display.name.filter { !$0.isWhitespace }.lowercased()
    let vendor = display.vendorNumber ?? 0
    let model = display.modelNumber ?? 0
    if CGDisplayIsBuiltin(display.identifier) != 0 {
      self.key = "builtin-\(normalizedName)-\(vendor)-\(model)"
    } else if let serialNumber = display.serialNumber, serialNumber != 0 {
      // Prefer the serial number so identical external displays keep separate curves.
      // 优先使用序列号，确保同型号外接显示器分别保存曲线。
      // Keep the original serialized shape for existing profiles.
      // 保留旧版序列化格式，兼容已经保存的配置。
      self.key = "external-\(normalizedName)-\(vendor)-\(model)-\(serialNumber)"
    } else {
      // Fall back to the current display ID when hardware does not expose a serial number.
      // 硬件不提供序列号时，回退到当前显示器 ID，避免同时连接的屏幕互相覆盖。
      self.key = "external-\(normalizedName)-\(vendor)-\(model)-display-\(display.identifier)"
    }
  }
}

/// Stores every saved curve and the reference display for one app installation.
/// 保存当前应用的一组曲线以及参考显示器身份。
struct EqualBrightnessSettingsProfile: Codable {
  static let currentSchemaVersion = 1

  var schemaVersion: Int = EqualBrightnessSettingsProfile.currentSchemaVersion
  var isEnabled: Bool = false
  var referenceDisplayKey: String?
  var curves: [String: EqualBrightnessCurve] = [:]
}

/// Persists equal-brightness curves separately from the legacy brightness preferences.
/// 将等亮度曲线与原有亮度偏好分开持久化。
final class EqualBrightnessSettingsStore {
  static let shared = EqualBrightnessSettingsStore()

  private let userDefaultsKey = "equalBrightnessSettings.profile.v1"
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  /// Creates a versioned JSON encoder and decoder for UserDefaults data.
  /// 创建用于 UserDefaults 数据的版本化 JSON 编解码器。
  private init() {
    self.encoder = JSONEncoder()
    self.decoder = JSONDecoder()
  }

  /// Loads a valid profile or returns nil when no profile has been saved.
  /// 读取有效配置；尚未保存配置时返回 nil。
  func load() -> EqualBrightnessSettingsProfile? {
    guard let data = UserDefaults.standard.data(forKey: self.userDefaultsKey) else {
      return nil
    }
    guard let profile = try? self.decoder.decode(EqualBrightnessSettingsProfile.self, from: data), profile.schemaVersion == EqualBrightnessSettingsProfile.currentSchemaVersion else {
      return nil
    }
    return profile
  }

  /// Saves a complete profile atomically after encoding it in memory.
  /// 先在内存中编码完整配置，再原子写入保存。
  @discardableResult
  func save(_ profile: EqualBrightnessSettingsProfile) -> Bool {
    guard let data = try? self.encoder.encode(profile) else {
      return false
    }
    UserDefaults.standard.set(data, forKey: self.userDefaultsKey)
    return true
  }

  /// Saves one target curve and enables mapped synchronization for future changes.
  /// 保存一台目标显示器的曲线，并为后续亮度变化启用映射同步。
  @discardableResult
  func saveCurve(_ curve: EqualBrightnessCurve, for targetDisplay: Display, referenceDisplay: Display) -> Bool {
    var profile = self.load() ?? EqualBrightnessSettingsProfile()
    let targetIdentity = EqualBrightnessDisplayIdentity(display: targetDisplay)
    let referenceIdentity = EqualBrightnessDisplayIdentity(display: referenceDisplay)
    profile.isEnabled = true
    profile.referenceDisplayKey = referenceIdentity.key
    profile.curves[targetIdentity.key] = curve
    return self.save(profile)
  }

  /// Returns the saved curve for a target display, if one exists.
  /// 返回目标显示器已保存的曲线；不存在时返回 nil。
  func curve(for display: Display) -> EqualBrightnessCurve? {
    guard let profile = self.load() else {
      return nil
    }
    let identity = EqualBrightnessDisplayIdentity(display: display)
    return profile.curves[identity.key]
  }

  /// Indicates whether a saved mapping should participate in runtime synchronization.
  /// 判断已保存的映射是否应参与运行时同步。
  func isEnabled() -> Bool {
    self.load()?.isEnabled ?? false
  }

  /// Checks whether a display is the configured reference display.
  /// 检查某台显示器是否为配置中的参考显示器。
  func isReferenceDisplay(_ display: Display) -> Bool {
    guard let configuredKey = self.load()?.referenceDisplayKey else {
      return false
    }
    return EqualBrightnessDisplayIdentity(display: display).key == configuredKey
  }

  /// Deletes all equal-brightness data and restores the disabled default.
  /// 删除全部等亮度数据并恢复为关闭状态。
  func reset() {
    UserDefaults.standard.removeObject(forKey: self.userDefaultsKey)
  }
}
