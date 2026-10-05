//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import Cocoa

/// A manually calibrated reference pair between the Mac display and one target display.
/// Mac 屏幕与目标显示器之间经过人工校准的一组参考点。
struct EqualBrightnessCalibrationPoint: Codable, Identifiable {
  let id: UUID
  var sourceValue: Double
  var targetValue: Double

  /// Creates a normalized calibration point and clamps both values to the supported range.
  /// 创建归一化参考点，并将两个值限制在支持的范围内。
  init(sourceValue: Double, targetValue: Double) {
    self.id = UUID()
    self.sourceValue = EqualBrightnessCurve.clamp(sourceValue)
    self.targetValue = EqualBrightnessCurve.clamp(targetValue)
  }
}

/// The first release keeps only monotonic curve choices that are safe to preview.
/// 第一版只提供适合预览且不会产生越界的曲线类型。
enum EqualBrightnessCurveKind: String, Codable, CaseIterable {
  case piecewiseLinear
  case monotoneCubic

  /// Returns the localized label shown in the curve selector.
  /// 返回曲线选择器中显示的本地化标题。
  var localizedTitle: String {
    switch self {
    case .piecewiseLinear:
      return NSLocalizedString("Piecewise Linear", comment: "Equal brightness curve type")
    case .monotoneCubic:
      return NSLocalizedString("Smooth Monotone Cubic", comment: "Equal brightness curve type")
    }
  }
}

/// Describes one target display mapping from reference brightness to target brightness.
/// 描述参考亮度到目标亮度映射的一条目标显示器曲线。
struct EqualBrightnessCurve: Codable {
  var kind: EqualBrightnessCurveKind
  var points: [EqualBrightnessCalibrationPoint]

  /// Evaluates the curve at a normalized reference brightness value.
  /// 根据归一化的参考亮度计算曲线输出。
  func value(at sourceValue: Double) -> Double {
    let source = Self.clamp(sourceValue)
    let result: Double
    switch self.kind {
    case .piecewiseLinear:
      result = self.piecewiseLinearValue(at: source)
    case .monotoneCubic:
      result = self.monotoneCubicValue(at: source)
    }
    return Self.clamp(result)
  }

  /// Performs a bounded piecewise-linear interpolation through the calibration points.
  /// 在参考点之间执行有界的分段线性插值。
  private func piecewiseLinearValue(at sourceValue: Double) -> Double {
    let sortedPoints = Self.pointsWithFixedEndpoints(self.points)
    guard let first = sortedPoints.first else {
      return sourceValue
    }
    guard sortedPoints.count > 1 else {
      return first.targetValue
    }
    if sourceValue <= first.sourceValue {
      return first.targetValue
    }
    if let last = sortedPoints.last, sourceValue >= last.sourceValue {
      return last.targetValue
    }
    for pair in zip(sortedPoints, sortedPoints.dropFirst()) {
      let left = pair.0
      let right = pair.1
      guard sourceValue <= right.sourceValue else {
        continue
      }
      let span = max(right.sourceValue - left.sourceValue, Double.ulpOfOne)
      let ratio = (sourceValue - left.sourceValue) / span
      return left.targetValue + (right.targetValue - left.targetValue) * ratio
    }
    return sourceValue
  }

  /// Adds immutable normalized endpoints and removes duplicate source positions.
  /// 添加固定的归一化端点，并移除重复的参考亮度位置。
  static func pointsWithFixedEndpoints(_ points: [EqualBrightnessCalibrationPoint]) -> [EqualBrightnessCalibrationPoint] {
    let tolerance = 0.000_001
    let sortedInterior = points
      .filter { $0.sourceValue > tolerance && $0.sourceValue < 1 - tolerance }
      .sorted { $0.sourceValue < $1.sourceValue }
    var result: [EqualBrightnessCalibrationPoint] = []
    for point in sortedInterior {
      if let last = result.last, abs(last.sourceValue - point.sourceValue) <= tolerance {
        result[result.count - 1].targetValue = Self.clamp(point.targetValue)
      } else {
        var normalized = point
        normalized.sourceValue = Self.clamp(normalized.sourceValue)
        normalized.targetValue = Self.clamp(normalized.targetValue)
        result.append(normalized)
      }
    }
    let lower = points.first(where: { abs($0.sourceValue) <= tolerance }) ?? EqualBrightnessCalibrationPoint(sourceValue: 0, targetValue: 0)
    let upper = points.first(where: { abs($0.sourceValue - 1) <= tolerance }) ?? EqualBrightnessCalibrationPoint(sourceValue: 1, targetValue: 1)
    var fixedLower = lower
    fixedLower.sourceValue = 0
    fixedLower.targetValue = 0
    var fixedUpper = upper
    fixedUpper.sourceValue = 1
    fixedUpper.targetValue = 1
    return [fixedLower] + result + [fixedUpper]
  }

  /// Evaluates a shape-preserving cubic Hermite spline through every point.
  /// 使用保形三次 Hermite 样条穿过每个参考点，同时保持曲线平滑。
  private func monotoneCubicValue(at sourceValue: Double) -> Double {
    let points = Self.pointsWithFixedEndpoints(self.points)
    guard points.count > 1 else {
      return sourceValue
    }
    if sourceValue <= points[0].sourceValue {
      return points[0].targetValue
    }
    if sourceValue >= points[points.count - 1].sourceValue {
      return points[points.count - 1].targetValue
    }
    let slopes = Self.monotoneSlopes(for: points)
    for index in 0 ..< points.count - 1 {
      let left = points[index]
      let right = points[index + 1]
      guard sourceValue <= right.sourceValue else {
        continue
      }
      let span = max(right.sourceValue - left.sourceValue, Double.ulpOfOne)
      let ratio = (sourceValue - left.sourceValue) / span
      let ratioSquared = ratio * ratio
      let ratioCubed = ratioSquared * ratio
      let h00 = 2 * ratioCubed - 3 * ratioSquared + 1
      let h10 = ratioCubed - 2 * ratioSquared + ratio
      let h01 = -2 * ratioCubed + 3 * ratioSquared
      let h11 = ratioCubed - ratioSquared
      return h00 * left.targetValue + h10 * span * slopes[index] + h01 * right.targetValue + h11 * span * slopes[index + 1]
    }
    return sourceValue
  }

  /// Calculates Fritsch-Carlson style slopes for a monotone cubic spline.
  /// 计算单调三次样条使用的 Fritsch-Carlson 风格切线斜率。
  private static func monotoneSlopes(for points: [EqualBrightnessCalibrationPoint]) -> [Double] {
    guard points.count > 2 else {
      let span = max(points[1].sourceValue - points[0].sourceValue, Double.ulpOfOne)
      let slope = (points[1].targetValue - points[0].targetValue) / span
      return [slope, slope]
    }
    var intervals: [Double] = []
    var widths: [Double] = []
    for pair in zip(points, points.dropFirst()) {
      let width = max(pair.1.sourceValue - pair.0.sourceValue, Double.ulpOfOne)
      widths.append(width)
      intervals.append((pair.1.targetValue - pair.0.targetValue) / width)
    }
    var slopes = [Double](repeating: 0, count: points.count)
    for index in 1 ..< points.count - 1 {
      let previous = intervals[index - 1]
      let next = intervals[index]
      if previous * next <= 0 {
        slopes[index] = 0
      } else {
        let weightPrevious = 2 * widths[index] + widths[index - 1]
        let weightNext = widths[index] + 2 * widths[index - 1]
        slopes[index] = (weightPrevious + weightNext) / (weightPrevious / previous + weightNext / next)
      }
    }
    slopes[0] = Self.endpointSlope(width: widths[0], nextWidth: widths[1], interval: intervals[0], nextInterval: intervals[1])
    slopes[slopes.count - 1] = Self.endpointSlope(width: widths[widths.count - 1], nextWidth: widths[widths.count - 2], interval: intervals[intervals.count - 1], nextInterval: intervals[intervals.count - 2])
    return slopes
  }

  /// Limits an endpoint tangent to the neighboring monotone interval.
  /// 将端点切线限制在相邻单调区间范围内。
  private static func endpointSlope(width: Double, nextWidth: Double, interval: Double, nextInterval: Double) -> Double {
    var slope = ((2 * width + nextWidth) * interval - width * nextInterval) / max(width + nextWidth, Double.ulpOfOne)
    if slope * interval <= 0 {
      slope = 0
    } else if interval * nextInterval < 0, abs(slope) > abs(3 * interval) {
      slope = 3 * interval
    }
    return slope
  }

  /// Clamps a curve value to the normalized brightness domain.
  /// 将曲线值限制在归一化亮度区间内。
  static func clamp(_ value: Double) -> Double {
    guard value.isFinite else {
      return 0
    }
    return max(0, min(1, value))
  }
}

/// A sampled curve used by the graph view without coupling the graph to display hardware.
/// 图表使用的采样曲线，避免图表直接依赖显示器硬件。
struct EqualBrightnessGraphCurve {
  let title: String
  let color: NSColor
  let evaluator: (Double) -> Double
  let isReference: Bool
}

/// Draws the normalized brightness grid, reference line, target curves, and calibration points.
/// 绘制归一化亮度网格、参考直线、目标曲线和校准点。
final class EqualBrightnessGraphView: NSView {
  var curves: [EqualBrightnessGraphCurve] = [] {
    didSet {
      self.needsDisplay = true
    }
  }

  var points: [EqualBrightnessCalibrationPoint] = [] {
    didSet {
      self.needsDisplay = true
    }
  }

  var selectedPointID: UUID? {
    didSet {
      self.needsDisplay = true
    }
  }

  var onPointSelected: ((UUID?) -> Void)?

  /// Keeps graph coordinates readable in both light and dark appearances.
  /// 让图表坐标在浅色和深色外观下都保持可读。
  override var isFlipped: Bool {
    true
  }

  /// Draws the grid and all current curve samples.
  /// 绘制网格以及当前的所有曲线采样点。
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    NSColor.windowBackgroundColor.setFill()
    dirtyRect.fill()
    let rect = self.plotRect()
    self.drawGrid(in: rect)
    for curve in self.curves {
      self.drawCurve(curve, in: rect)
    }
    self.drawLegend(in: rect)
    for point in self.points {
      self.drawPoint(point, in: rect)
    }
  }

  /// Selects the closest reference point when the graph is clicked.
  /// 点击图表时选中距离最近的参考点。
  override func mouseDown(with event: NSEvent) {
    let location = self.convert(event.locationInWindow, from: nil)
    let rect = self.plotRect()
    let nearest = self.points
      .map { point in (point, hypot(self.graphPoint(source: point.sourceValue, target: point.targetValue, in: rect).x - location.x, self.graphPoint(source: point.sourceValue, target: point.targetValue, in: rect).y - location.y)) }
      .filter { $0.1 <= 12 }
      .min { $0.1 < $1.1 }
    self.selectedPointID = nearest?.0.id
    self.onPointSelected?(self.selectedPointID)
  }

  /// Calculates the inset plotting rectangle used by the graph.
  /// 计算图表实际绘图区的内边距矩形。
  private func plotRect() -> NSRect {
    self.bounds.insetBy(dx: 36, dy: 24)
  }

  /// Draws five-by-five grid divisions and the two coordinate axes.
  /// 绘制五乘五网格以及两条坐标轴。
  private func drawGrid(in rect: NSRect) {
    let gridColor = NSColor.separatorColor.withAlphaComponent(0.55)
    gridColor.setStroke()
    let path = NSBezierPath()
    path.lineWidth = 0.5
    for index in 0...4 {
      let ratio = CGFloat(index) / 4
      let x = rect.minX + rect.width * ratio
      let y = rect.minY + rect.height * ratio
      path.move(to: NSPoint(x: x, y: rect.minY))
      path.line(to: NSPoint(x: x, y: rect.maxY))
      path.move(to: NSPoint(x: rect.minX, y: y))
      path.line(to: NSPoint(x: rect.maxX, y: y))
    }
    path.stroke()

    NSColor.secondaryLabelColor.setStroke()
    let axes = NSBezierPath()
    axes.lineWidth = 1
    axes.move(to: NSPoint(x: rect.minX, y: rect.minY))
    axes.line(to: NSPoint(x: rect.maxX, y: rect.minY))
    axes.move(to: NSPoint(x: rect.minX, y: rect.minY))
    axes.line(to: NSPoint(x: rect.minX, y: rect.maxY))
    axes.stroke()
  }

  /// Samples one normalized curve and renders it as a smooth polyline.
  /// 对一条归一化曲线采样，并绘制为连续折线。
  private func drawCurve(_ curve: EqualBrightnessGraphCurve, in rect: NSRect) {
    let path = NSBezierPath()
    path.lineWidth = curve.isReference ? 1 : 2
    curve.color.withAlphaComponent(curve.isReference ? 0.65 : 0.9).setStroke()
    for index in 0...60 {
      let source = Double(index) / 60
      let target = EqualBrightnessCurve.clamp(curve.evaluator(source))
      let point = self.graphPoint(source: source, target: target, in: rect)
      if index == 0 {
        path.move(to: point)
      } else {
        path.line(to: point)
      }
    }
    if curve.isReference {
      path.setLineDash([4, 3], count: 2, phase: 0)
    }
    path.stroke()
  }

  /// Renders one calibration point as a colored marker.
  /// 将一个校准点绘制为彩色标记。
  private func drawPoint(_ point: EqualBrightnessCalibrationPoint, in rect: NSRect) {
    let center = self.graphPoint(source: point.sourceValue, target: point.targetValue, in: rect)
    if point.id == self.selectedPointID {
      let selection = NSBezierPath(ovalIn: NSRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16))
      NSColor.controlAccentColor.setStroke()
      selection.lineWidth = 2
      selection.stroke()
    }
    let marker = NSBezierPath(ovalIn: NSRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8))
    NSColor.systemOrange.setFill()
    marker.fill()
    NSColor.labelColor.setStroke()
    marker.lineWidth = 1
    marker.stroke()
  }

  /// Draws a compact legend using the actual display names for every curve.
  /// 使用每台显示器的实际名称绘制紧凑图例。
  private func drawLegend(in rect: NSRect) {
    var origin = NSPoint(x: rect.minX + 8, y: rect.minY + 8)
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
      .foregroundColor: NSColor.labelColor
    ]
    for curve in self.curves {
      let title = NSString(string: curve.title)
      let size = title.size(withAttributes: attributes)
      let swatch = NSBezierPath(roundedRect: NSRect(x: origin.x, y: origin.y + 4, width: 12, height: 3), xRadius: 1.5, yRadius: 1.5)
      curve.color.setStroke()
      swatch.lineWidth = 2
      swatch.stroke()
      title.draw(at: NSPoint(x: origin.x + 16, y: origin.y), withAttributes: attributes)
      origin.x += 16 + size.width + 18
      if origin.x > rect.maxX - 100 {
        origin.x = rect.minX + 8
        origin.y += 18
      }
    }
  }

  /// Converts normalized values into the flipped view coordinate system.
  /// 将归一化数值转换为翻转坐标系中的绘图位置。
  private func graphPoint(source: Double, target: Double, in rect: NSRect) -> NSPoint {
    let x = rect.minX + rect.width * CGFloat(EqualBrightnessCurve.clamp(source))
    let y = rect.maxY - rect.height * CGFloat(EqualBrightnessCurve.clamp(target))
    return NSPoint(x: x, y: y)
  }
}

/// Hosts the first functional equal-brightness editor window.
/// 承载第一版可操作的等亮度设置窗口。
final class EqualBrightnessSettingsViewController: NSViewController {
  var onSave: (([EqualBrightnessCalibrationPoint], EqualBrightnessCurveKind) -> Void)?
  var onCancel: (() -> Void)?

  private let graphView = EqualBrightnessGraphView(frame: .zero)
  private let displayPopup = NSPopUpButton(frame: .zero, pullsDown: false)
  private let curvePopup = NSPopUpButton(frame: .zero, pullsDown: false)
  private let sourceSlider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
  private let targetSlider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
  private let sourceBrightnessLabel = NSTextField(labelWithString: "")
  private let targetBrightnessLabel = NSTextField(labelWithString: "")
  private let pointsSummary = NSTextField(labelWithString: "")
  private var removePointButton: NSButton?
  private var points: [EqualBrightnessCalibrationPoint] = []
  private var curveKind: EqualBrightnessCurveKind = .monotoneCubic
  private var displayNames: [String] = []
  private var displayObjects: [Display] = []
  private var referenceDisplay: Display?
  private var selectedPointID: UUID?

  /// Builds the settings view hierarchy using AppKit controls and Auto Layout.
  /// 使用 AppKit 控件和自动布局创建设置窗口的视图层级。
  override func loadView() {
    let rootView = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 560))
    let titleLabel = NSTextField(labelWithString: NSLocalizedString("Equal Brightness Settings", comment: "Equal brightness window title"))
    titleLabel.font = NSFont.boldSystemFont(ofSize: 18)

    self.displayNames = self.loadDisplayNames()
    self.displayPopup.addItems(withTitles: self.displayNames)
    self.displayPopup.target = self
    self.displayPopup.action = #selector(self.displayChanged(_:))

    self.curvePopup.addItems(withTitles: EqualBrightnessCurveKind.allCases.map { $0.localizedTitle })
    self.curvePopup.selectItem(at: 0)
    self.curvePopup.target = self
    self.curvePopup.action = #selector(self.curveChanged(_:))

    self.sourceSlider.target = self
    self.sourceSlider.action = #selector(self.sliderChanged(_:))
    self.targetSlider.target = self
    self.targetSlider.action = #selector(self.sliderChanged(_:))

    let addPointButton = NSButton(title: NSLocalizedString("Add Reference Point", comment: "Equal brightness add point button"), target: self, action: #selector(self.addReferencePoint(_:)))
    let removePointButton = NSButton(title: NSLocalizedString("Delete Selected Point", comment: "Equal brightness delete point button"), target: self, action: #selector(self.removeSelectedPoint(_:)))
    self.removePointButton = removePointButton
    let previewLabel = NSTextField(labelWithString: NSLocalizedString("Adjust both sliders until the displays look equally bright, then record the point.", comment: "Equal brightness calibration guidance"))
    previewLabel.textColor = .secondaryLabelColor
    previewLabel.lineBreakMode = .byWordWrapping

    self.pointsSummary.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    self.pointsSummary.textColor = .secondaryLabelColor
    self.pointsSummary.lineBreakMode = .byWordWrapping
    self.pointsSummary.maximumNumberOfLines = 3

    let graphContainer = NSView(frame: .zero)
    graphContainer.addSubview(self.graphView)
    self.graphView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      self.graphView.leadingAnchor.constraint(equalTo: graphContainer.leadingAnchor),
      self.graphView.trailingAnchor.constraint(equalTo: graphContainer.trailingAnchor),
      self.graphView.topAnchor.constraint(equalTo: graphContainer.topAnchor),
      self.graphView.bottomAnchor.constraint(equalTo: graphContainer.bottomAnchor),
      graphContainer.heightAnchor.constraint(equalToConstant: 300)
    ])

    let controls = NSStackView(views: [
      self.makeRow(labelView: self.sourceBrightnessLabel, control: self.sourceSlider),
      self.makeRow(labelView: self.targetBrightnessLabel, control: self.targetSlider),
      self.makeRow(label: NSLocalizedString("Curve type", comment: "Equal brightness curve selector label"), control: self.curvePopup),
      NSStackView(views: [addPointButton, removePointButton])
    ])
    controls.orientation = .vertical
    controls.alignment = .leading
    controls.spacing = 8

    let header = NSStackView(views: [
      NSTextField(labelWithString: NSLocalizedString("Target display", comment: "Equal brightness target display label")),
      self.displayPopup
    ])
    header.orientation = .horizontal
    header.alignment = .centerY
    header.spacing = 8

    let footer = NSStackView()
    footer.orientation = .horizontal
    footer.alignment = .centerY
    footer.spacing = 8
    let cancelButton = NSButton(title: NSLocalizedString("Cancel", comment: "Equal brightness cancel button"), target: self, action: #selector(self.cancel(_:)))
    let saveButton = NSButton(title: NSLocalizedString("Save", comment: "Equal brightness save button"), target: self, action: #selector(self.save(_:)))
    saveButton.keyEquivalent = "\r"
    cancelButton.keyEquivalent = "\u{1b}"
    footer.addArrangedSubview(NSView())
    footer.addArrangedSubview(cancelButton)
    footer.addArrangedSubview(saveButton)

    let rootStack = NSStackView(views: [titleLabel, header, graphContainer, previewLabel, controls, self.pointsSummary, footer])
    rootStack.orientation = .vertical
    rootStack.alignment = .leading
    rootStack.spacing = 12
    rootStack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
    rootStack.translatesAutoresizingMaskIntoConstraints = false
    rootView.addSubview(rootStack)
    NSLayoutConstraint.activate([
      rootStack.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
      rootStack.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
      rootStack.topAnchor.constraint(equalTo: rootView.topAnchor),
      rootStack.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
      self.displayPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
      self.curvePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
      self.sourceSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
      self.targetSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
      footer.widthAnchor.constraint(equalTo: rootStack.widthAnchor, constant: -40),
      graphContainer.widthAnchor.constraint(equalTo: rootStack.widthAnchor, constant: -40),
      previewLabel.widthAnchor.constraint(equalTo: rootStack.widthAnchor, constant: -40),
      self.pointsSummary.widthAnchor.constraint(equalTo: rootStack.widthAnchor, constant: -40)
    ])
    self.graphView.onPointSelected = { [weak self] pointID in
      self?.selectedPointID = pointID
      self?.updateRemovePointButtonState()
      self?.graphView.selectedPointID = pointID
    }
    self.view = rootView
    self.loadWorkingCurveForSelectedDisplay()
    self.refreshDisplayControls()
  }

  /// Refreshes the graph after the view has been loaded.
  /// 视图加载后刷新曲线图。
  override func viewDidLoad() {
    super.viewDidLoad()
    self.refreshGraph()
  }

  /// Creates one labeled horizontal control row.
  /// 创建一个带标签的水平控件行。
  private func makeRow(label: String, control: NSView) -> NSStackView {
    let labelView = NSTextField(labelWithString: label)
    return self.makeRow(labelView: labelView, control: control)
  }

  /// Creates one labeled row using a reusable label for display-name updates.
  /// 使用可复用标签创建一行控件，以便动态更新显示器名称。
  private func makeRow(labelView: NSTextField, control: NSView) -> NSStackView {
    labelView.setContentHuggingPriority(.required, for: .horizontal)
    let row = NSStackView(views: [labelView, control])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 8
    return row
  }

  /// Loads display names while keeping the editor usable before display discovery completes.
  /// 读取显示器名称，并在显示器发现尚未完成时保持编辑器可用。
  private func loadDisplayNames() -> [String] {
    let allDisplays = DisplayManager.shared.displays.filter { !$0.isDummy }
    self.referenceDisplay = DisplayManager.shared.getBuiltInDisplay() ?? DisplayManager.shared.getAppleDisplays().first ?? allDisplays.first
    self.displayObjects = allDisplays.filter { display in
      guard let referenceDisplay = self.referenceDisplay else {
        return true
      }
      return display != referenceDisplay
    }
    let names = self.displayObjects.enumerated().map { index, display in
      DisplayManager.shared.userFacingDisplayName(for: display, fallbackIndex: index)
    }
    if names.isEmpty {
      return [NSLocalizedString("External Display", comment: "Fallback display name")]
    }
    return names
  }

  /// Handles a change to the selected target display.
  /// 处理目标显示器选择变化。
  @objc private func displayChanged(_: NSPopUpButton) {
    self.loadWorkingCurveForSelectedDisplay()
    self.refreshDisplayControls()
    self.refreshGraph()
  }

  /// Returns the currently selected display object when display discovery supplied one.
  /// 当显示器发现提供了对象时，返回当前选中的显示器对象。
  private func selectedDisplay() -> Display? {
    let index = self.displayPopup.indexOfSelectedItem
    guard index >= 0, index < self.displayObjects.count else {
      return nil
    }
    return self.displayObjects[index]
  }

  /// Updates slider labels and initial values using the actual display identities.
  /// 使用实际显示器名称更新滑块标签和初始值。
  private func refreshDisplayControls() {
    let referenceName = self.referenceDisplay.map {
      DisplayManager.shared.userFacingDisplayName(for: $0)
    } ?? NSLocalizedString("Built-in Display", comment: "Fallback built-in display name")
    let targetName = self.selectedDisplay().map {
      let index = self.displayPopup.indexOfSelectedItem
      return DisplayManager.shared.userFacingDisplayName(for: $0, fallbackIndex: max(index, 0))
    } ?? self.displayNames.first ?? NSLocalizedString("External Display", comment: "Fallback external display name")
    let brightnessTitle = NSLocalizedString("Brightness", comment: "Display brightness label")
    self.sourceBrightnessLabel.stringValue = "\(referenceName) \(brightnessTitle)"
    self.targetBrightnessLabel.stringValue = "\(targetName) \(brightnessTitle)"
    self.sourceSlider.doubleValue = self.referenceDisplay.map { self.currentBrightness(for: $0) } ?? 0.5
    self.targetSlider.doubleValue = self.selectedDisplay().map { self.currentBrightness(for: $0) } ?? 0.5
    self.displayPopup.isEnabled = !self.displayObjects.isEmpty
    self.updateRemovePointButtonState()
  }

  /// Reads the current normalized brightness without changing the display.
  /// 读取当前归一化亮度，不修改显示器状态。
  private func currentBrightness(for display: Display) -> Double {
    if let appleDisplay = display as? AppleDisplay {
      return Double(appleDisplay.getAppleBrightness())
    }
    return Double(display.getBrightness())
  }

  /// Returns whether a point is one of the protected zero or full brightness endpoints.
  /// 判断参考点是否为受保护的零亮度或满亮度端点。
  private func isFixedEndpoint(_ point: EqualBrightnessCalibrationPoint) -> Bool {
    abs(point.sourceValue) <= 0.000_001 || abs(point.sourceValue - 1) <= 0.000_001
  }

  /// Enables deletion only for a selected editable reference point.
  /// 只有选中了可编辑参考点时才启用删除按钮。
  private func updateRemovePointButtonState() {
    guard let selectedPointID = self.selectedPointID,
          let point = self.points.first(where: { $0.id == selectedPointID }) else {
      self.removePointButton?.isEnabled = false
      return
    }
    self.removePointButton?.isEnabled = !self.isFixedEndpoint(point)
  }

  /// Loads the selected display curve into the editable working state.
  /// 将当前显示器的已保存曲线加载到可编辑工作状态。
  private func loadWorkingCurveForSelectedDisplay() {
    guard let display = self.selectedDisplay(), let curve = EqualBrightnessSettingsStore.shared.curve(for: display) else {
      self.points = EqualBrightnessCurve.pointsWithFixedEndpoints([])
      self.curveKind = .monotoneCubic
      if let index = EqualBrightnessCurveKind.allCases.firstIndex(of: self.curveKind) {
        self.curvePopup.selectItem(at: index)
      }
      self.selectedPointID = nil
      return
    }
    self.points = EqualBrightnessCurve.pointsWithFixedEndpoints(curve.points)
    self.curveKind = curve.kind
    self.selectedPointID = nil
    if let index = EqualBrightnessCurveKind.allCases.firstIndex(of: curve.kind) {
      self.curvePopup.selectItem(at: index)
    }
  }

  /// Updates the working curve type without writing preferences.
  /// 更新工作曲线类型，但不写入持久化偏好。
  @objc private func curveChanged(_ sender: NSPopUpButton) {
    let index = sender.indexOfSelectedItem
    guard index >= 0, index < EqualBrightnessCurveKind.allCases.count else {
      return
    }
    self.curveKind = EqualBrightnessCurveKind.allCases[index]
    self.refreshGraph()
  }

  /// Redraws the preview when either calibration slider changes.
  /// 任一校准滑块变化时刷新预览图。
  @objc private func sliderChanged(_ sender: NSSlider) {
    if sender === self.sourceSlider, let referenceDisplay = self.referenceDisplay {
      self.applyBrightness(self.sourceSlider.doubleValue, to: referenceDisplay)
    } else if sender === self.targetSlider, let targetDisplay = self.selectedDisplay() {
      self.applyBrightness(self.targetSlider.doubleValue, to: targetDisplay)
    }
    self.refreshGraph()
  }

  /// Applies a calibration slider value to the actual display immediately.
  /// 将校准滑块值立即应用到实际显示器。
  private func applyBrightness(_ value: Double, to display: Display) {
    _ = display.setDirectBrightness(Float(EqualBrightnessCurve.clamp(value)))
  }

  /// Adds a reference point from the current pair of calibration sliders.
  /// 根据当前两个校准滑块的值添加一个参考点。
  @objc private func addReferencePoint(_: NSButton) {
    let point = EqualBrightnessCalibrationPoint(sourceValue: self.sourceSlider.doubleValue, targetValue: self.targetSlider.doubleValue)
    let tolerance = 0.000_001
    if let index = self.points.firstIndex(where: { abs($0.sourceValue - point.sourceValue) <= tolerance }) {
      if self.isFixedEndpoint(self.points[index]) {
        self.selectedPointID = self.points[index].id
      } else {
        self.points[index].targetValue = point.targetValue
        self.selectedPointID = self.points[index].id
      }
    } else {
      self.points.append(point)
      self.selectedPointID = point.id
    }
    self.points = EqualBrightnessCurve.pointsWithFixedEndpoints(self.points)
    self.refreshGraph()
  }

  /// Deletes the selected non-endpoint point without touching saved settings.
  /// 删除选中的非端点参考点，不影响已保存设置。
  @objc private func removeSelectedPoint(_: NSButton) {
    guard let selectedPointID = self.selectedPointID,
          let index = self.points.firstIndex(where: { $0.id == selectedPointID }),
          !self.isFixedEndpoint(self.points[index]) else {
      return
    }
    self.points.remove(at: index)
    self.selectedPointID = nil
    self.points = EqualBrightnessCurve.pointsWithFixedEndpoints(self.points)
    self.refreshGraph()
  }

  /// Sends the working points to the window controller for the save transaction.
  /// 将工作参考点交给窗口控制器执行保存事务。
  @objc private func save(_: NSButton) {
    self.points = EqualBrightnessCurve.pointsWithFixedEndpoints(self.points)
    let curve = EqualBrightnessCurve(kind: self.curveKind, points: self.points)
    if let targetDisplay = self.selectedDisplay(), let referenceDisplay = self.referenceDisplay {
      _ = EqualBrightnessSettingsStore.shared.saveCurve(curve, for: targetDisplay, referenceDisplay: referenceDisplay)
    }
    self.onSave?(self.points, self.curveKind)
    self.view.window?.close()
  }

  /// Closes the editor without persisting the working points.
  /// 关闭编辑器且不保存当前工作参考点。
  @objc private func cancel(_: NSButton) {
    self.onCancel?()
    self.view.window?.close()
  }

  /// Rebuilds the graph curves and the human-readable point summary.
  /// 重建图表曲线和可读的参考点摘要。
  private func refreshGraph() {
    let referenceTitle = self.referenceDisplay.map {
      DisplayManager.shared.userFacingDisplayName(for: $0)
    } ?? NSLocalizedString("Mac Reference", comment: "Equal brightness reference curve")
    var curves: [EqualBrightnessGraphCurve] = [
      EqualBrightnessGraphCurve(
        title: referenceTitle,
        color: .systemBlue,
        evaluator: { $0 },
        isReference: true
      )
    ]
    let palette: [NSColor] = [.systemOrange, .systemGreen, .systemPurple, .systemRed]
    for (index, display) in self.displayObjects.enumerated() {
      let name = DisplayManager.shared.userFacingDisplayName(for: display, fallbackIndex: index)
      let curve: EqualBrightnessCurve
      if index == self.displayPopup.indexOfSelectedItem {
        curve = EqualBrightnessCurve(kind: self.curveKind, points: self.points)
      } else if let savedCurve = EqualBrightnessSettingsStore.shared.curve(for: display) {
        curve = savedCurve
      } else {
        curve = EqualBrightnessCurve(kind: .piecewiseLinear, points: [])
      }
      curves.append(
        EqualBrightnessGraphCurve(
          title: name,
          color: palette[index % palette.count],
          evaluator: { curve.value(at: $0) },
          isReference: false
        )
      )
    }
    self.graphView.curves = curves
    self.graphView.points = self.points
    self.graphView.selectedPointID = self.selectedPointID
    self.updateRemovePointButtonState()
    if self.points.isEmpty {
      self.pointsSummary.stringValue = NSLocalizedString("No reference points yet.", comment: "Equal brightness empty point summary")
    } else {
      self.pointsSummary.stringValue = self.points.map {
        String(format: "%.0f%% → %.0f%%", $0.sourceValue * 100, $0.targetValue * 100)
      }.joined(separator: "   ")
    }
  }
}

/// Owns the equal-brightness window and keeps the view controller alive while it is shown.
/// 管理等亮度窗口，并在窗口显示期间保持视图控制器有效。
final class EqualBrightnessSettingsWindowController: NSWindowController, NSWindowDelegate {
  var onSave: (([EqualBrightnessCalibrationPoint], EqualBrightnessCurveKind) -> Void)?
  var onCancel: (() -> Void)?
  private var didFinish = false

  /// Creates a resizable AppKit settings window with the functional editor view.
  /// 创建一个可调整大小、包含功能编辑器视图的 AppKit 设置窗口。
  init() {
    let viewController = EqualBrightnessSettingsViewController()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.contentViewController = viewController
    window.title = NSLocalizedString("Equal Brightness Settings", comment: "Equal brightness window title")
    super.init(window: window)
    window.delegate = self
    viewController.onSave = { [weak self] points, curveKind in
      self?.didFinish = true
      EqualBrightnessSyncCoordinator.shared.endCalibrationSession()
      self?.onSave?(points, curveKind)
    }
    viewController.onCancel = { [weak self] in
      self?.didFinish = true
      EqualBrightnessSyncCoordinator.shared.endCalibrationSession()
      self?.onCancel?()
    }
  }

  /// Required initializer for storyboard and nib compatibility.
  /// 为兼容 storyboard 和 nib 提供必需的初始化方法。
  required init?(coder: NSCoder) {
    super.init(coder: coder)
  }

  /// Presents the window and activates the application for immediate editing.
  /// 显示窗口并激活应用，确保用户可以立即编辑。
  func showSettings() {
    self.didFinish = false
    EqualBrightnessSyncCoordinator.shared.beginCalibrationSession()
    self.window?.center()
    self.showWindow(nil)
    self.window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  /// Treats a window-close button click as a cancellation when no explicit action ran.
  /// 如果用户直接关闭窗口且没有点击明确按钮，则按取消处理。
  func windowWillClose(_: Notification) {
    EqualBrightnessSyncCoordinator.shared.endCalibrationSession()
    guard !self.didFinish else {
      return
    }
    self.didFinish = true
    self.onCancel?()
  }
}
