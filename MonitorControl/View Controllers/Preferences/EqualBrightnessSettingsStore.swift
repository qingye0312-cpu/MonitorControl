//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import Cocoa
import Foundation

/// Identifies a display with stable hardware values and keeps legacy aliases for migration.
/// 使用稳定硬件字段标识显示器，并保留旧键以便迁移已有配置。
struct EqualBrightnessDisplayIdentity: Codable, Hashable {
  let key: String
  let displayName: String
  private let legacyKeys: [String]

  /// Returns the current key followed by keys written by older builds.
  /// 返回当前键以及旧版本写入的兼容键。
  var lookupKeys: [String] {
    var keys = [self.key]
    for legacyKey in self.legacyKeys where !keys.contains(legacyKey) {
      keys.append(legacyKey)
    }
    return keys
  }

  /// Builds a stable identity from the current display metadata.
  /// 根据当前显示器元数据构造稳定身份。
  init(display: Display) {
    self.displayName = display.name
    let localizedName = Self.normalized(display.name)
    let hardwareName = Self.normalized(DisplayManager.getDisplayRawNameByID(displayID: display.identifier))
    let stableName = hardwareName.isEmpty ? localizedName : hardwareName
    let vendor = display.vendorNumber ?? 0
    let model = display.modelNumber ?? 0
    let serial = display.serialNumber ?? 0
    let unit = CGDisplayUnitNumber(display.identifier)
    let isBuiltin = CGDisplayIsBuiltin(display.identifier) != 0

    if isBuiltin {
      // Built-in displays are unique on a Mac, so vendor/model are sufficient when no serial exists.
      // 内置屏幕在一台 Mac 上唯一；没有序列号时使用厂商/型号即可。
      self.key = serial == 0 ? "builtin-\(vendor)-\(model)" : "builtin-\(vendor)-\(model)-serial-\(serial)"
    } else if serial != 0 {
      // Serial numbers keep identical external displays separate after reconnects.
      // 序列号可让同型号外接显示器在重连后仍保持独立配置。
      self.key = "external-\(vendor)-\(model)-serial-\(serial)"
    } else if !stableName.isEmpty, unit != 0 {
      // Unit number represents the physical display connection and survives display-ID reassignment.
      // 显示单元号代表物理连接，显示器 ID 重新分配后通常仍保持不变。
      self.key = "external-\(vendor)-\(model)-name-\(stableName)-unit-\(unit)"
    } else if !stableName.isEmpty {
      // Keep a metadata-only fallback when the system does not expose a unit number.
      // 系统不提供显示单元号时，至少使用显示器元数据作为稳定回退。
      self.key = "external-\(vendor)-\(model)-name-\(stableName)"
    } else {
      // A display ID is the last resort when no identifying metadata is available at all.
      // 完全没有可识别元数据时，最后才回退到当前显示器 ID。
      self.key = "external-display-\(display.identifier)"
    }

    // Keep both the original serial/zero format and the display-ID fallback used by recent builds.
    // 同时兼容最初的序列号/0 格式，以及近期版本使用的显示器 ID 回退格式。
    var aliases: [String] = []
    if isBuiltin {
      aliases.append("builtin-\(localizedName)-\(vendor)-\(model)")
      if hardwareName != localizedName, !hardwareName.isEmpty {
        aliases.append("builtin-\(hardwareName)-\(vendor)-\(model)")
      }
    } else {
      aliases.append("external-\(localizedName)-\(vendor)-\(model)-\(serial)")
      aliases.append("external-\(localizedName)-\(vendor)-\(model)-display-\(display.identifier)")
      if hardwareName != localizedName, !hardwareName.isEmpty {
        aliases.append("external-\(hardwareName)-\(vendor)-\(model)-\(serial)")
        aliases.append("external-\(hardwareName)-\(vendor)-\(model)-display-\(display.identifier)")
      }
    }
    self.legacyKeys = aliases
  }

  /// Normalizes names without tying persistence to localization or whitespace.
  /// 规范化名称，避免持久化结果依赖语言设置或空白字符。
  private static func normalized(_ value: String) -> String {
    value.filter { !$0.isWhitespace }.lowercased()
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
    for key in identity.lookupKeys {
      if let curve = profile.curves[key] {
        return curve
      }
    }
    return nil
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
    return EqualBrightnessDisplayIdentity(display: display).lookupKeys.contains(configuredKey)
  }

  /// Deletes all equal-brightness data and restores the disabled default.
  /// 删除全部等亮度数据并恢复为关闭状态。
  func reset() {
    UserDefaults.standard.removeObject(forKey: self.userDefaultsKey)
  }
}
