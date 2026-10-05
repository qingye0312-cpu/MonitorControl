//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import Cocoa

// MARK: - Curve model / 曲线模型

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

// MARK: - Graph / 曲线图

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

  /// Uses the selected target display color for its calibration markers.
  /// 使用当前选中目标显示器的颜色绘制校准点。
  var pointColor: NSColor = .systemOrange {
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
    self.drawReferenceGuides(in: rect)
    for curve in self.curves {
      self.drawCurve(curve, in: rect)
    }
    self.drawLegend(in: rect)
    for point in self.points {
      self.drawPoint(point, in: rect)
    }
  }

  /// Selects the closest reference point guide when the graph is clicked.
  /// 点击图表时选中距离最近的参考点纵向引导线。
  override func mouseDown(with event: NSEvent) {
    let location = self.convert(event.locationInWindow, from: nil)
    let rect = self.plotRect()
    guard rect.insetBy(dx: -12, dy: 0).contains(location) else {
      return
    }
    let candidates: [(point: EqualBrightnessCalibrationPoint, distance: CGFloat)] = self.points.map { point in
      let pointX = self.graphPoint(source: point.sourceValue, target: point.targetValue, in: rect).x
      return (point: point, distance: abs(pointX - location.x))
    }
    let nearest = candidates
      .filter { candidate in candidate.distance <= 12 }
      .min { left, right in left.distance < right.distance }
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

  /// Draws one gray vertical guide for every reference point.
  /// 为每个参考点绘制一条灰色纵向引导线。
  private func drawReferenceGuides(in rect: NSRect) {
    let guideColor = NSColor.systemGray.withAlphaComponent(0.6)
    guideColor.setStroke()
    for point in self.points {
      let x = self.graphPoint(source: point.sourceValue, target: point.targetValue, in: rect).x
      let guide = NSBezierPath()
      guide.lineWidth = point.id == self.selectedPointID ? 1.5 : 1
      guide.setLineDash([3, 3], count: 2, phase: 0)
      guide.move(to: NSPoint(x: x, y: rect.minY))
      guide.line(to: NSPoint(x: x, y: rect.maxY))
      guide.stroke()
    }
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
    self.pointColor.setFill()
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

// MARK: - Settings editor / 设置编辑器

/// Keeps the editor's content dimensions in one place so the view and window stay in sync.
/// 集中管理编辑器内容尺寸，确保视图和窗口尺寸保持一致。
private enum EqualBrightnessSettingsLayout {
  static let contentSize = NSSize(width: 760, height: 800)
  static let minimumContentSize = NSSize(width: 680, height: 760)
  static let contentInset: CGFloat = 24
  static let sectionSpacing: CGFloat = 16
  static let headerHeight: CGFloat = 32
  static let graphHeight: CGFloat = 300
  static let summaryHeight: CGFloat = 128
  static let footerHeight: CGFloat = 32
}

/// Lays out one slider row with a shared label column and track origin.
/// 使用统一的标签列和滑块起点布局一行亮度滑块。
private final class EqualBrightnessAlignedSliderRow: NSView {
  static let labelColumnWidth: CGFloat = 190

  let label: NSTextField
  let slider: NSSlider

  init(label: NSTextField, slider: NSSlider) {
    self.label = label
    self.slider = slider
    super.init(frame: .zero)
    self.label.lineBreakMode = .byTruncatingTail
    self.addSubview(label)
    self.addSubview(slider)
  }

  required init?(coder: NSCoder) {
    fatalError("EqualBrightnessAlignedSliderRow does not support storyboard decoding")
  }

  override var isFlipped: Bool {
    true
  }

  override func layout() {
    super.layout()
    let labelWidth = Self.labelColumnWidth
    let sliderX = labelWidth + 12
    let sliderHeight: CGFloat = 24
    self.label.frame = NSRect(x: 0, y: 0, width: labelWidth, height: self.bounds.height)
    self.slider.frame = NSRect(
      x: sliderX,
      y: max(0, (self.bounds.height - sliderHeight) / 2),
      width: max(0, self.bounds.width - sliderX),
      height: sliderHeight
    )
  }
}

/// Lays out a labeled control using the same column as the live sliders.
/// 使用与实时滑块相同的标签列布局带标签控件。
private final class EqualBrightnessAlignedControlRow: NSView {
  private let label: NSTextField
  private let control: NSView

  init(label: NSTextField, control: NSView) {
    self.label = label
    self.control = control
    super.init(frame: .zero)
    self.label.lineBreakMode = .byTruncatingTail
    self.addSubview(label)
    self.addSubview(control)
  }

  required init?(coder: NSCoder) {
    fatalError("EqualBrightnessAlignedControlRow does not support storyboard decoding")
  }

  override var isFlipped: Bool {
    true
  }

  override func layout() {
    super.layout()
    let labelWidth = EqualBrightnessAlignedSliderRow.labelColumnWidth
    let controlX = labelWidth + 12
    self.label.frame = NSRect(x: 0, y: 0, width: labelWidth, height: self.bounds.height)
    self.control.frame = NSRect(
      x: controlX,
      y: max(0, (self.bounds.height - 28) / 2),
      width: max(0, self.bounds.width - controlX),
      height: 28
    )
  }
}

/// Owns the calibration controls and keeps all live sliders aligned.
/// 管理校准控件，并确保所有实时滑块对齐。
private final class EqualBrightnessCalibrationControlsView: NSView {
  private let sliderRows: [EqualBrightnessAlignedSliderRow]
  private let curveRow: EqualBrightnessAlignedControlRow
  private let addButton: NSButton
  private let removeButton: NSButton

  init(sliderRows: [EqualBrightnessAlignedSliderRow], curveRow: EqualBrightnessAlignedControlRow, addButton: NSButton, removeButton: NSButton) {
    self.sliderRows = sliderRows
    self.curveRow = curveRow
    self.addButton = addButton
    self.removeButton = removeButton
    super.init(frame: .zero)
    for row in sliderRows {
      self.addSubview(row)
    }
    self.addSubview(curveRow)
    self.addSubview(addButton)
    self.addSubview(removeButton)
  }

  required init?(coder: NSCoder) {
    fatalError("EqualBrightnessCalibrationControlsView does not support storyboard decoding")
  }

  override var isFlipped: Bool {
    true
  }

  /// Returns the exact height needed for all display sliders and actions.
  /// 返回所有显示器滑块和操作按钮所需的准确高度。
  var contentHeight: CGFloat {
    let rowHeight: CGFloat = 32
    let rowSpacing: CGFloat = 8
    return CGFloat(self.sliderRows.count + 2) * rowHeight + CGFloat(self.sliderRows.count + 1) * rowSpacing
  }

  override func layout() {
    super.layout()
    let rowHeight: CGFloat = 32
    let rowSpacing: CGFloat = 8
    for (index, row) in self.sliderRows.enumerated() {
      row.frame = NSRect(x: 0, y: CGFloat(index) * (rowHeight + rowSpacing), width: self.bounds.width, height: rowHeight)
    }
    let curveY = CGFloat(self.sliderRows.count) * (rowHeight + rowSpacing)
    self.curveRow.frame = NSRect(x: 0, y: curveY, width: self.bounds.width, height: rowHeight)
    let buttonY = curveY + rowHeight + rowSpacing
    self.addButton.frame = NSRect(x: 0, y: buttonY, width: max(132, self.addButton.fittingSize.width), height: rowHeight)
    self.removeButton.frame = NSRect(x: self.addButton.frame.maxX + rowSpacing, y: buttonY, width: max(190, self.removeButton.fittingSize.width), height: rowHeight)
  }
}

/// Places the target-display selector without relying on the host preferences layout.
/// 独立放置目标显示器选择器，不依赖宿主偏好设置页面布局。
private final class EqualBrightnessDisplaySelectorView: NSView {
  private let label: NSTextField
  private let popup: NSPopUpButton

  init(label: NSTextField, popup: NSPopUpButton) {
    self.label = label
    self.popup = popup
    super.init(frame: .zero)
    self.label.lineBreakMode = .byTruncatingTail
    self.addSubview(label)
    self.addSubview(popup)
  }

  required init?(coder: NSCoder) {
    fatalError("EqualBrightnessDisplaySelectorView does not support storyboard decoding")
  }

  override var isFlipped: Bool {
    true
  }

  override func layout() {
    super.layout()
    let labelWidth = EqualBrightnessAlignedSliderRow.labelColumnWidth
    let popupX = labelWidth + 12
    self.label.frame = NSRect(x: 0, y: 0, width: labelWidth, height: self.bounds.height)
    self.popup.frame = NSRect(x: popupX, y: 0, width: min(260, max(220, self.bounds.width - popupX)), height: 28)
  }
}

/// Places Cancel and Save at the bottom-right of the standalone page.
/// 将“取消”和“保存”固定在独立页面右下角。
private final class EqualBrightnessActionBar: NSView {
  private let cancelButton: NSButton
  private let saveButton: NSButton

  init(cancelButton: NSButton, saveButton: NSButton) {
    self.cancelButton = cancelButton
    self.saveButton = saveButton
    super.init(frame: .zero)
    self.addSubview(cancelButton)
    self.addSubview(saveButton)
  }

  required init?(coder: NSCoder) {
    fatalError("EqualBrightnessActionBar does not support storyboard decoding")
  }

  override var isFlipped: Bool {
    true
  }

  override func layout() {
    super.layout()
    let spacing: CGFloat = 12
    let buttonHeight: CGFloat = 32
    let saveWidth = max(88, self.saveButton.fittingSize.width)
    let cancelWidth = max(88, self.cancelButton.fittingSize.width)
    self.saveButton.frame = NSRect(x: self.bounds.width - saveWidth, y: 0, width: saveWidth, height: buttonHeight)
    self.cancelButton.frame = NSRect(x: self.saveButton.frame.minX - spacing - cancelWidth, y: 0, width: cancelWidth, height: buttonHeight)
  }
}

/// Provides a complete standalone page with explicit top-to-bottom frames.
/// 提供使用明确上下位置的完整独立页面。
private final class EqualBrightnessSettingsPageView: NSView {
  private let displaySelector: EqualBrightnessDisplaySelectorView
  private let graphView: EqualBrightnessGraphView
  private let controlsView: EqualBrightnessCalibrationControlsView
  private let pointsSummary: NSTextField
  private let actionBar: EqualBrightnessActionBar

  init(displaySelector: EqualBrightnessDisplaySelectorView, graphView: EqualBrightnessGraphView, controlsView: EqualBrightnessCalibrationControlsView, pointsSummary: NSTextField, actionBar: EqualBrightnessActionBar) {
    self.displaySelector = displaySelector
    self.graphView = graphView
    self.controlsView = controlsView
    self.pointsSummary = pointsSummary
    self.actionBar = actionBar
    super.init(frame: NSRect(origin: .zero, size: EqualBrightnessSettingsLayout.contentSize))
    self.autoresizingMask = [.width, .height]
    self.addSubview(displaySelector)
    self.addSubview(graphView)
    self.addSubview(controlsView)
    self.addSubview(pointsSummary)
    self.addSubview(actionBar)
  }

  required init?(coder: NSCoder) {
    fatalError("EqualBrightnessSettingsPageView does not support storyboard decoding")
  }

  override var isFlipped: Bool {
    true
  }

  /// Calculates the minimum content height for the discovered display count.
  /// 根据当前发现的显示器数量计算页面所需的最小内容高度。
  var requiredContentHeight: CGFloat {
    let sectionCount = 5
    return EqualBrightnessSettingsLayout.contentInset * 2
      + EqualBrightnessSettingsLayout.headerHeight
      + EqualBrightnessSettingsLayout.graphHeight
      + self.controlsView.contentHeight
      + EqualBrightnessSettingsLayout.summaryHeight
      + EqualBrightnessSettingsLayout.footerHeight
      + CGFloat(sectionCount - 1) * EqualBrightnessSettingsLayout.sectionSpacing
  }

  override func layout() {
    super.layout()
    let inset = EqualBrightnessSettingsLayout.contentInset
    let spacing = EqualBrightnessSettingsLayout.sectionSpacing
    let width = max(0, self.bounds.width - inset * 2)
    var y = inset

    // Keep the graph as the first content block, directly below the window title bar.
    // 将曲线图作为第一个内容区块，直接放在窗口标题栏下方。
    self.graphView.frame = NSRect(x: inset, y: y, width: width, height: EqualBrightnessSettingsLayout.graphHeight)
    y += EqualBrightnessSettingsLayout.graphHeight + spacing

    self.displaySelector.frame = NSRect(x: inset, y: y, width: width, height: EqualBrightnessSettingsLayout.headerHeight)
    y += EqualBrightnessSettingsLayout.headerHeight + spacing

    let controlsHeight = self.controlsView.contentHeight
    self.controlsView.frame = NSRect(x: inset, y: y, width: width, height: controlsHeight)
    y += controlsHeight + spacing

    // Keep the point summary and usage guidance together immediately before the actions.
    // 将参考点摘要和使用提示作为同一个文本区块，放在操作按钮之前。
    let minimumFooterY = y + spacing + EqualBrightnessSettingsLayout.summaryHeight + spacing
    let footerY = max(minimumFooterY, self.bounds.height - inset - EqualBrightnessSettingsLayout.footerHeight)
    let summaryY = footerY - spacing - EqualBrightnessSettingsLayout.summaryHeight
    self.pointsSummary.frame = NSRect(x: inset, y: summaryY, width: width, height: EqualBrightnessSettingsLayout.summaryHeight)
    self.pointsSummary.preferredMaxLayoutWidth = width
    self.actionBar.frame = NSRect(x: inset, y: footerY, width: width, height: EqualBrightnessSettingsLayout.footerHeight)
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
  private let pointsSummary = NSTextField(labelWithString: "")
  private let targetDisplayColors: [NSColor] = [
    .systemOrange,
    .systemGreen,
    .systemPurple,
    .systemRed,
    .systemPink,
    .systemTeal,
    .systemYellow,
    .systemIndigo,
    .systemBrown,
    .systemMint,
    .systemCyan
  ]
  private var liveSliderRows: [EqualBrightnessAlignedSliderRow] = []
  private var sliderDisplays: [ObjectIdentifier: Display] = [:]
  private var slidersByDisplayID: [CGDirectDisplayID: NSSlider] = [:]
  private var displayColors: [CGDirectDisplayID: NSColor] = [:]
  private var removePointButton: NSButton?
  private var points: [EqualBrightnessCalibrationPoint] = []
  private var curveKind: EqualBrightnessCurveKind = .monotoneCubic
  private var displayNames: [String] = []
  private var displayObjects: [Display] = []
  private var referenceDisplay: Display?
  private var selectedPointID: UUID?

  /// Builds the standalone page without inheriting layout from the host preferences window.
  /// 创建独立页面，不继承宿主偏好设置窗口的布局。
  override func loadView() {
    self.configureInteractiveControls()

    let header = self.makeDisplayHeader()
    let controls = self.makeCalibrationControls()
    let footer = self.makeFooter()
    let rootView = EqualBrightnessSettingsPageView(
      displaySelector: header,
      graphView: self.graphView,
      controlsView: controls,
      pointsSummary: self.pointsSummary,
      actionBar: footer
    )

    // Keep graph selection in the view controller so button state follows the selected point.
    // 将图表选中状态交给视图控制器管理，使按钮状态随选中点更新。
    self.graphView.onPointSelected = { [weak self] pointID in
      self?.selectedPointID = pointID
      self?.applySelectedPointToAllDisplays()
      self?.refreshGraph()
      self?.updateRemovePointButtonState()
      self?.graphView.selectedPointID = pointID
    }
    self.view = rootView
    self.loadWorkingCurveForSelectedDisplay()
    self.refreshDisplayControls()
  }

  /// Configures all controls that send editing events to this view controller.
  /// 配置所有向当前视图控制器发送编辑事件的控件。
  private func configureInteractiveControls() {
    self.displayNames = self.loadDisplayNames()
    self.displayPopup.removeAllItems()
    self.displayPopup.addItems(withTitles: self.displayNames)
    self.displayPopup.target = self
    self.displayPopup.action = #selector(self.displayChanged(_:))

    self.curvePopup.removeAllItems()
    self.curvePopup.addItems(withTitles: EqualBrightnessCurveKind.allCases.map { $0.localizedTitle })
    self.curvePopup.selectItem(at: 0)
    self.curvePopup.target = self
    self.curvePopup.action = #selector(self.curveChanged(_:))

    self.pointsSummary.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    self.pointsSummary.textColor = .secondaryLabelColor
    self.pointsSummary.lineBreakMode = .byWordWrapping
    self.pointsSummary.maximumNumberOfLines = 0
    self.pointsSummary.usesSingleLineMode = false
    self.pointsSummary.cell?.wraps = true
    self.pointsSummary.cell?.isScrollable = false
  }

  /// Creates one aligned live slider per discovered display plus the calibration actions.
  /// 为发现到的每台显示器创建一个对齐的实时滑块，并创建校准操作。
  private func makeCalibrationControls() -> EqualBrightnessCalibrationControlsView {
    let addPointButton = NSButton(title: NSLocalizedString("Add Reference Point", comment: "Equal brightness add point button"), target: self, action: #selector(self.addReferencePoint(_:)))
    let removePointButton = NSButton(title: NSLocalizedString("Delete Selected Point", comment: "Equal brightness delete point button"), target: self, action: #selector(self.removeSelectedPoint(_:)))
    self.removePointButton = removePointButton
    let curveLabel = NSTextField(labelWithString: NSLocalizedString("Curve type", comment: "Equal brightness curve selector label"))
    let curveRow = EqualBrightnessAlignedControlRow(label: curveLabel, control: self.curvePopup)
    let displays = ([self.referenceDisplay] + self.displayObjects).compactMap { $0 }
    self.liveSliderRows = displays.map { display in
      let slider = NSSlider(value: self.currentBrightness(for: display), minValue: 0, maxValue: 1, target: self, action: #selector(self.sliderChanged(_:)))
      slider.isContinuous = true
      let targetIndex = self.displayObjects.firstIndex(where: { $0.identifier == display.identifier }) ?? 0
      let color = display == self.referenceDisplay ? NSColor.systemBlue : self.color(for: display, targetIndex: targetIndex)
      slider.trackFillColor = color
      let label = NSTextField(labelWithString: "")
      self.sliderDisplays[ObjectIdentifier(slider)] = display
      self.slidersByDisplayID[display.identifier] = slider
      return EqualBrightnessAlignedSliderRow(label: label, slider: slider)
    }
    return EqualBrightnessCalibrationControlsView(
      sliderRows: self.liveSliderRows,
      curveRow: curveRow,
      addButton: addPointButton,
      removeButton: removePointButton
    )
  }

  /// Creates the target-display selector using the same fixed label column as the sliders.
  /// 使用与滑块相同的固定标签列创建目标显示器选择器。
  private func makeDisplayHeader() -> EqualBrightnessDisplaySelectorView {
    let label = NSTextField(labelWithString: NSLocalizedString("Target display", comment: "Equal brightness target display label"))
    return EqualBrightnessDisplaySelectorView(label: label, popup: self.displayPopup)
  }

  /// Creates Save and Cancel actions with a stable bottom-right layout.
  /// 创建具有稳定右下角布局的“保存”和“取消”操作。
  private func makeFooter() -> EqualBrightnessActionBar {
    let cancelButton = NSButton(title: NSLocalizedString("Cancel", comment: "Equal brightness cancel button"), target: self, action: #selector(self.cancel(_:)))
    let saveButton = NSButton(title: NSLocalizedString("Save", comment: "Equal brightness save button"), target: self, action: #selector(self.save(_:)))
    saveButton.keyEquivalent = "\r"
    cancelButton.keyEquivalent = "\u{1b}"
    return EqualBrightnessActionBar(cancelButton: cancelButton, saveButton: saveButton)
  }

  /// Refreshes the graph after the view has been loaded.
  /// 视图加载后刷新曲线图。
  override func viewDidLoad() {
    super.viewDidLoad()
    self.refreshGraph()
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

  /// Returns the reference display followed by every target display in slider order.
  /// 按滑块顺序返回参考显示器和全部目标显示器。
  private func calibrationDisplays() -> [Display] {
    ([self.referenceDisplay] + self.displayObjects).compactMap { $0 }
  }

  /// Finds the live slider associated with one physical display.
  /// 查找与某台实际显示器关联的实时滑块。
  private func slider(for display: Display) -> NSSlider? {
    self.slidersByDisplayID[display.identifier]
  }

  /// Finds the physical display controlled by a slider event.
  /// 根据滑块事件查找对应的实际显示器。
  private func display(for slider: NSSlider) -> Display? {
    self.sliderDisplays[ObjectIdentifier(slider)]
  }

  /// Returns a stable, distinct color for each target display.
  /// 为每台目标显示器返回稳定且彼此区分的颜色。
  private func color(for display: Display, targetIndex: Int) -> NSColor {
    if let existingColor = self.displayColors[display.identifier] {
      return existingColor
    }
    let color: NSColor
    if targetIndex < self.targetDisplayColors.count {
      color = self.targetDisplayColors[targetIndex]
    } else {
      // Golden-ratio hue spacing keeps additional displays visually distinct.
      // 使用黄金比例间隔色相，让更多显示器仍保持视觉区分度。
      let hue = CGFloat((Double(targetIndex) * 0.618_033_988_75).truncatingRemainder(dividingBy: 1))
      color = NSColor(calibratedHue: hue, saturation: 0.72, brightness: 0.92, alpha: 1)
    }
    self.displayColors[display.identifier] = color
    return color
  }

  /// Updates slider labels and initial values using the actual display identities.
  /// 使用实际显示器名称更新滑块标签和初始值。
  private func refreshDisplayControls() {
    let brightnessTitle = NSLocalizedString("Brightness", comment: "Display brightness label")
    for (index, display) in self.calibrationDisplays().enumerated() where index < self.liveSliderRows.count {
      let name = DisplayManager.shared.userFacingDisplayName(for: display, fallbackIndex: index)
      let row = self.liveSliderRows[index]
      row.label.stringValue = "\(name) \(brightnessTitle)"
      row.slider.doubleValue = self.currentBrightness(for: display)
    }
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

  /// Applies any display slider immediately and redraws the preview.
  /// 立即应用任意显示器滑块的值并刷新预览图。
  @objc private func sliderChanged(_ sender: NSSlider) {
    guard let display = self.display(for: sender) else {
      return
    }
    self.applyBrightness(sender.doubleValue, to: display)
    // Manual changes leave the previously selected point so the next saved point reflects the sliders.
    // 手动调整后取消旧的选中点，确保下一次保存记录当前滑块值。
    self.selectedPointID = nil
    self.refreshGraph()
  }

  /// Applies a calibration slider value to the actual display immediately.
  /// 将校准滑块值立即应用到实际显示器。
  private func applyBrightness(_ value: Double, to display: Display) {
    _ = display.setDirectBrightness(Float(EqualBrightnessCurve.clamp(value)))
  }

  /// Moves every live slider to the selected point and applies each value to its display.
  /// 将所有实时滑块移动到选中参考点，并把对应值写入每台显示器。
  private func applySelectedPointToAllDisplays() {
    guard let selectedPointID = self.selectedPointID,
          let selectedPoint = self.points.first(where: { $0.id == selectedPointID }) else {
      return
    }
    let selectedTarget = self.selectedDisplay()
    let sourceValue = selectedPoint.sourceValue
    for display in self.calibrationDisplays() {
      let value: Double
      if display == self.referenceDisplay {
        value = sourceValue
      } else if display == selectedTarget {
        value = selectedPoint.targetValue
      } else if let savedCurve = EqualBrightnessSettingsStore.shared.curve(for: display) {
        value = savedCurve.value(at: sourceValue)
      } else {
        // An uncalibrated target follows the reference value until it has its own curve.
        // 尚未校准的目标显示器在拥有独立曲线前跟随参考亮度。
        value = sourceValue
      }
      guard let slider = self.slider(for: display) else {
        continue
      }
      slider.doubleValue = EqualBrightnessCurve.clamp(value)
      self.applyBrightness(value, to: display)
    }
  }

  /// Adds a reference point from the current pair of calibration sliders.
  /// 根据当前参考显示器和选中目标显示器的滑块值添加一个参考点。
  @objc private func addReferencePoint(_: NSButton) {
    guard let referenceDisplay = self.referenceDisplay,
          let targetDisplay = self.selectedDisplay(),
          let sourceSlider = self.slider(for: referenceDisplay),
          let targetSlider = self.slider(for: targetDisplay) else {
      return
    }
    let point = EqualBrightnessCalibrationPoint(sourceValue: sourceSlider.doubleValue, targetValue: targetSlider.doubleValue)
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
    for (index, display) in self.displayObjects.enumerated() {
      let name = DisplayManager.shared.userFacingDisplayName(for: display, fallbackIndex: index)
      let displayColor = self.color(for: display, targetIndex: index)
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
          color: displayColor,
          evaluator: { curve.value(at: $0) },
          isReference: false
        )
      )
    }
    self.graphView.curves = curves
    self.graphView.points = self.points
    self.graphView.selectedPointID = self.selectedPointID
    if let selectedDisplay = self.selectedDisplay() {
      self.graphView.pointColor = self.color(for: selectedDisplay, targetIndex: self.displayPopup.indexOfSelectedItem)
    } else {
      self.graphView.pointColor = .systemOrange
    }
    self.updateRemovePointButtonState()
    let pointSummary: String
    if self.points.isEmpty {
      pointSummary = NSLocalizedString("No reference points yet.", comment: "Equal brightness empty point summary")
    } else {
      pointSummary = self.points.map {
        String(format: "%.0f%% → %.0f%%", $0.sourceValue * 100, $0.targetValue * 100)
      }.joined(separator: "   ")
    }

    // Reuse the visible point-summary control so the guidance has exactly the same typography and color.
    // 复用已经可见的参考点摘要控件，确保提示使用完全相同的字体和颜色。
    let instruction = NSLocalizedString("Equal brightness instructions", comment: "Equal brightness usage instructions")
    // Leave one empty line between the point summary and the bilingual usage guide.
    // 在参考点摘要和双语使用说明之间保留一个空行。
    self.pointsSummary.stringValue = "\(pointSummary)\n\n\(instruction)"
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
      contentRect: NSRect(origin: .zero, size: EqualBrightnessSettingsLayout.contentSize),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.contentMinSize = EqualBrightnessSettingsLayout.minimumContentSize
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
    if let pageView = self.window?.contentViewController?.view as? EqualBrightnessSettingsPageView,
       let window = self.window {
      let currentSize = window.contentView?.bounds.size ?? EqualBrightnessSettingsLayout.contentSize
      let requiredHeight = max(EqualBrightnessSettingsLayout.minimumContentSize.height, pageView.requiredContentHeight)
      window.contentMinSize = NSSize(width: EqualBrightnessSettingsLayout.minimumContentSize.width, height: requiredHeight)
      if currentSize.height < requiredHeight {
        window.setContentSize(NSSize(width: max(currentSize.width, EqualBrightnessSettingsLayout.contentSize.width), height: requiredHeight))
      }
    }
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
