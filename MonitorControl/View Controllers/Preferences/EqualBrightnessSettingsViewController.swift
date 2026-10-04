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
  case linear
  case power
  case piecewiseLinear

  /// Returns the localized label shown in the curve selector.
  /// 返回曲线选择器中显示的本地化标题。
  var localizedTitle: String {
    switch self {
    case .linear:
      return NSLocalizedString("Linear", comment: "Equal brightness curve type")
    case .power:
      return NSLocalizedString("Power", comment: "Equal brightness curve type")
    case .piecewiseLinear:
      return NSLocalizedString("Piecewise Linear", comment: "Equal brightness curve type")
    }
  }
}

/// Describes one target display mapping from reference brightness to target brightness.
/// 描述参考亮度到目标亮度映射的一条目标显示器曲线。
struct EqualBrightnessCurve: Codable {
  var kind: EqualBrightnessCurveKind
  var points: [EqualBrightnessCalibrationPoint]
  var gamma: Double = 1

  /// Evaluates the curve at a normalized reference brightness value.
  /// 根据归一化的参考亮度计算曲线输出。
  func value(at sourceValue: Double) -> Double {
    let source = Self.clamp(sourceValue)
    let result: Double
    switch self.kind {
    case .linear:
      result = source
    case .power:
      result = pow(source, max(0.25, min(4, self.gamma)))
    case .piecewiseLinear:
      result = self.piecewiseLinearValue(at: source)
    }
    return Self.clamp(result)
  }

  /// Performs a bounded piecewise-linear interpolation through the calibration points.
  /// 在参考点之间执行有界的分段线性插值。
  private func piecewiseLinearValue(at sourceValue: Double) -> Double {
    let sortedPoints = self.points.sorted { $0.sourceValue < $1.sourceValue }
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
    for point in self.points {
      self.drawPoint(point, in: rect)
    }
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
    let marker = NSBezierPath(ovalIn: NSRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8))
    NSColor.systemOrange.setFill()
    marker.fill()
    NSColor.labelColor.setStroke()
    marker.lineWidth = 1
    marker.stroke()
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
  private let pointsSummary = NSTextField(labelWithString: "")
  private var points: [EqualBrightnessCalibrationPoint] = []
  private var curveKind: EqualBrightnessCurveKind = .linear
  private var displayNames: [String] = []

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
    let removePointButton = NSButton(title: NSLocalizedString("Remove Last Point", comment: "Equal brightness remove point button"), target: self, action: #selector(self.removeLastPoint(_:)))
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
      self.makeRow(label: NSLocalizedString("Reference display brightness", comment: "Equal brightness source slider label"), control: self.sourceSlider),
      self.makeRow(label: NSLocalizedString("Target display brightness", comment: "Equal brightness target slider label"), control: self.targetSlider),
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
    self.view = rootView
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
    let names = DisplayManager.shared.displays.map { $0.name }
    if names.isEmpty {
      return [NSLocalizedString("External Display", comment: "Fallback display name")]
    }
    return names
  }

  /// Handles a change to the selected target display.
  /// 处理目标显示器选择变化。
  @objc private func displayChanged(_: NSPopUpButton) {
    self.points.removeAll()
    self.refreshGraph()
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
  @objc private func sliderChanged(_: NSSlider) {
    self.refreshGraph()
  }

  /// Adds a reference point from the current pair of calibration sliders.
  /// 根据当前两个校准滑块的值添加一个参考点。
  @objc private func addReferencePoint(_: NSButton) {
    let point = EqualBrightnessCalibrationPoint(sourceValue: self.sourceSlider.doubleValue, targetValue: self.targetSlider.doubleValue)
    self.points.append(point)
    self.points.sort { $0.sourceValue < $1.sourceValue }
    self.refreshGraph()
  }

  /// Removes the last point in the working set without touching saved settings.
  /// 删除当前工作集合中的最后一个点，不影响已保存设置。
  @objc private func removeLastPoint(_: NSButton) {
    guard !self.points.isEmpty else {
      return
    }
    self.points.removeLast()
    self.refreshGraph()
  }

  /// Sends the working points to the window controller for the save transaction.
  /// 将工作参考点交给窗口控制器执行保存事务。
  @objc private func save(_: NSButton) {
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
    let selectedCurve = EqualBrightnessCurve(kind: self.curveKind, points: self.points)
    var curves: [EqualBrightnessGraphCurve] = [
      EqualBrightnessGraphCurve(
        title: NSLocalizedString("Mac Reference", comment: "Equal brightness reference curve"),
        color: .systemBlue,
        evaluator: { $0 },
        isReference: true
      )
    ]
    let palette: [NSColor] = [.systemOrange, .systemGreen, .systemPurple, .systemRed]
    for (index, name) in self.displayNames.enumerated() {
      curves.append(
        EqualBrightnessGraphCurve(
          title: name,
          color: palette[index % palette.count],
          evaluator: { selectedCurve.value(at: $0) },
          isReference: false
        )
      )
    }
    self.graphView.curves = curves
    self.graphView.points = self.points
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
      self?.onSave?(points, curveKind)
    }
    viewController.onCancel = { [weak self] in
      self?.didFinish = true
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
    self.window?.center()
    self.showWindow(nil)
    self.window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  /// Treats a window-close button click as a cancellation when no explicit action ran.
  /// 如果用户直接关闭窗口且没有点击明确按钮，则按取消处理。
  func windowWillClose(_: Notification) {
    guard !self.didFinish else {
      return
    }
    self.didFinish = true
    self.onCancel?()
  }
}
