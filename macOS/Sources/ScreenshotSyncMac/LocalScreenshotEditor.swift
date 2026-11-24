import AppKit
import CoreText
import SwiftUI

private enum ScreenshotTool: String, CaseIterable, Sendable {
    case arrow = "箭头"
    case rectangle = "矩形"
    case pen = "画笔"
    case text = "文字"
    case crop = "裁剪"

    var icon: String {
        switch self {
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .pen: "pencil.tip"
        case .text: "textformat"
        case .crop: "crop"
        }
    }
}

private struct ScreenshotMark: Sendable {
    let tool: ScreenshotTool
    let start: CGPoint
    var end: CGPoint
    var points: [CGPoint] = []
    let color: CGColor
    let width: CGFloat
    var text = ""
    var textArea = CGSize.zero

    var bounds: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    func draw(in context: CGContext) {
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setStrokeColor(color)
        context.setFillColor(color)
        switch tool {
        case .rectangle:
            context.stroke(bounds)
        case .pen:
            if points.isEmpty {
                context.fillEllipse(in: CGRect(x: start.x - width / 2, y: start.y - width / 2,
                                               width: width, height: width))
            } else {
                context.beginPath()
                context.move(to: start)
                for point in points { context.addLine(to: point) }
                context.strokePath()
            }
        case .arrow:
            let dx = end.x - start.x, dy = end.y - start.y
            let length = hypot(dx, dy)
            guard length > 0 else { return }
            let head = min(width * 5, length * 0.55)
            let tail = CGPoint(x: end.x - dx / length * head, y: end.y - dy / length * head)
            let wing = CGPoint(x: -dy / length * head * 0.45, y: dx / length * head * 0.45)
            context.beginPath()
            context.move(to: start)
            context.addLine(to: tail)
            context.strokePath()
            context.move(to: end)
            context.addLine(to: CGPoint(x: tail.x + wing.x, y: tail.y + wing.y))
            context.addLine(to: CGPoint(x: tail.x - wing.x, y: tail.y - wing.y))
            context.closePath()
            context.fillPath()
        case .text:
            guard !text.isEmpty, textArea.width > 0, textArea.height > 0 else { return }
            let font = CTFontCreateUIFontForLanguage(.system, width * 5, nil)
                ?? CTFontCreateWithName("Helvetica" as CFString, width * 5, nil)
            let string = NSAttributedString(string: text, attributes: [
                .font: font, kCTForegroundColorFromContextAttributeName as NSAttributedString.Key: true
            ])
            let framesetter = CTFramesetterCreateWithAttributedString(string)
            let path = CGPath(rect: CGRect(origin: .zero, size: textArea), transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
            context.saveGState()
            context.translateBy(x: end.x, y: end.y + textArea.height)
            context.scaleBy(x: 1, y: -1)
            context.textMatrix = .identity
            CTFrameDraw(frame, context)
            context.restoreGState()
        case .crop:
            break
        }
    }
}

private enum ScreenshotEdit: Sendable {
    case mark(ScreenshotMark)
    case crop(CGRect)
}

// Edits use the original image's pixels, measured from its top-left corner.
private struct ScreenshotDocument: Sendable {
    let image: CGImage
    var edits: [ScreenshotEdit] = []
    var undone: [ScreenshotEdit] = []

    var bounds: CGRect { CGRect(x: 0, y: 0, width: image.width, height: image.height) }

    var crop: CGRect {
        for case .crop(let rect) in edits.reversed() { return rect }
        return bounds
    }

    mutating func commit(_ mark: ScreenshotMark, minimumDrag: CGFloat) {
        if mark.tool == .crop {
            let rect = mark.bounds.integral.intersection(crop)
            guard min(mark.bounds.width, mark.bounds.height) >= minimumDrag, !rect.isEmpty, rect != crop else { return }
            edits.append(.crop(rect))
        } else {
            switch mark.tool {
            case .text:
                guard !mark.text.isEmpty, min(mark.textArea.width, mark.textArea.height) >= mark.width * 5 else { return }
            case .rectangle:
                guard min(mark.bounds.width, mark.bounds.height) >= minimumDrag else { return }
            case .arrow:
                guard hypot(mark.end.x - mark.start.x, mark.end.y - mark.start.y) >= minimumDrag else { return }
            case .pen, .crop:
                break
            }
            edits.append(.mark(mark))
        }
        undone.removeAll()
    }

    mutating func undo() {
        if let last = edits.popLast() { undone.append(last) }
    }

    mutating func redo() {
        if let last = undone.popLast() { edits.append(last) }
    }

    func draw(in context: CGContext, frame: CGRect, draft: ScreenshotMark? = nil) {
        let crop = crop
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: frame)
        context.translateBy(x: frame.minX, y: frame.minY)
        let scale = frame.width / crop.width
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -crop.minX, y: -crop.minY)
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(image, in: bounds)
        context.restoreGState()
        for case .mark(let mark) in edits { mark.draw(in: context) }
        if let draft {
            if draft.tool == .crop {
                context.addRect(crop)
                context.addRect(draft.bounds)
                context.setFillColor(gray: 0, alpha: 0.45)
                context.fillPath(using: .evenOdd)
                context.setStrokeColor(gray: 1, alpha: 1)
                context.setLineWidth(1.5 / scale)
                context.stroke(draft.bounds)
            } else {
                draft.draw(in: context)
            }
        }
    }

    func rendered() throws -> CGImage {
        if edits.isEmpty { return image }
        let crop = crop
        if !edits.contains(where: { if case .mark = $0 { true } else { false } }),
           let result = image.cropping(to: crop) { return result }
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: Int(crop.width), height: Int(crop.height),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw EditorError.render
        }
        context.translateBy(x: 0, y: crop.height)
        context.scaleBy(x: 1, y: -1)
        draw(in: context, frame: CGRect(origin: .zero, size: crop.size))
        guard let result = context.makeImage() else { throw EditorError.render }
        return result
    }
}

private enum EditorError: LocalizedError {
    case render, copy
    var errorDescription: String? {
        switch self {
        case .render: "无法生成编辑后的截图。"
        case .copy: "无法将截图写入剪贴板。"
        }
    }
}

struct LocalScreenshotEditor: View {
    let onSave: (CGImage) async throws -> Void
    let onClose: () -> Void
    @State private var document: ScreenshotDocument
    @State private var tool = ScreenshotTool.arrow
    @State private var color = Color(red: 1, green: 0.22, blue: 0.17)
    @State private var draft: ScreenshotMark?
    @State private var error: String?
    @State private var copied = false
    @State private var busy = false
    @State private var annotation = ""
    @FocusState private var textFocused: Bool

    init(image: CGImage, onSave: @escaping (CGImage) async throws -> Void, onClose: @escaping () -> Void) {
        _document = State(initialValue: ScreenshotDocument(image: image))
        self.onSave = onSave
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("编辑工具", selection: $tool) {
                    ForEach(ScreenshotTool.allCases, id: \.self) { tool in
                        Label(tool.rawValue, systemImage: tool.icon).tag(tool)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                ColorPicker("标注颜色", selection: $color, supportsOpacity: false)
                    .labelsHidden()
                    .disabled(tool == .crop)
                    .help("标注颜色")
                Spacer(minLength: 4)
                Button {
                    document.undo()
                    copied = false
                } label: { Image(systemName: "arrow.uturn.backward") }
                .accessibilityLabel("撤销")
                .help("撤销")
                .keyboardShortcut(textFocused ? nil : KeyboardShortcut("z", modifiers: .command))
                .disabled(document.edits.isEmpty)
                Button {
                    document.redo()
                    copied = false
                } label: { Image(systemName: "arrow.uturn.forward") }
                .accessibilityLabel("重做")
                .help("重做")
                .keyboardShortcut(textFocused ? nil : KeyboardShortcut("z", modifiers: [.shift, .command]))
                .disabled(document.undone.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            if tool == .text {
                HStack {
                    TextField("输入标注文字", text: $annotation)
                        .textFieldStyle(.roundedBorder)
                        .focused($textFocused)
                        .onAppear { textFocused = true }
                        .accessibilityIdentifier("local-screenshot-text")
                    Text("点按截图放置").font(.callout).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
            Divider()
            drawingArea
            Divider()
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Int(document.crop.width)) × \(Int(document.crop.height)) px")
                        .font(.callout.monospacedDigit())
                    if tool == .crop {
                        Text("拖动框选要保留的区域").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("取消", action: onClose).keyboardShortcut(.cancelAction)
                Button {
                    copyImage()
                } label: {
                    Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .keyboardShortcut(textFocused ? nil : KeyboardShortcut("c", modifiers: .command))
                Button("保存到图库", action: saveImage)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
        }
        .frame(minWidth: 550, minHeight: 335)
        .disabled(busy)
        .alert("编辑截图", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private func saveImage() {
        guard !busy else { return }
        busy = true
        let snapshot = document
        Task {
            defer { busy = false }
            do {
                let result = try await Task.detached(priority: .userInitiated) { try snapshot.rendered() }.value
                try await onSave(result)
                onClose()
            } catch { self.error = error.localizedDescription }
        }
    }

    private func copyImage() {
        guard !busy else { return }
        busy = true
        let snapshot = document
        Task {
            defer { busy = false }
            do {
                let png = try await Task.detached(priority: .userInitiated) {
                    let bitmap = NSBitmapImageRep(cgImage: try snapshot.rendered())
                    guard let data = bitmap.representation(using: .png, properties: [:]) else { throw EditorError.copy }
                    return data
                }.value
                let item = NSPasteboardItem()
                guard item.setData(png, forType: .png) else { throw EditorError.copy }
                NSPasteboard.general.clearContents()
                guard NSPasteboard.general.writeObjects([item]) else { throw EditorError.copy }
                copied = true
            } catch { self.error = error.localizedDescription }
        }
    }

    private var drawingArea: some View {
        GeometryReader { geometry in
            let crop = document.crop
            let size = geometry.size
            let scale = min(max(1, size.width - 32) / crop.width, max(1, size.height - 32) / crop.height)
            let frame = CGRect(x: (size.width - crop.width * scale) / 2, y: (size.height - crop.height * scale) / 2,
                               width: crop.width * scale, height: crop.height * scale)
            Canvas { canvas, _ in
                canvas.withCGContext { document.draw(in: $0, frame: frame, draft: draft) }
            }
            .background(Color(nsColor: .underPageBackgroundColor))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard frame.contains(value.startLocation) else { return }
                    draft = updatedMark(for: value, crop: crop, frame: frame, scale: scale)
                }
                .onEnded { value in
                    defer { draft = nil }
                    guard frame.contains(value.startLocation) else { return }
                    textFocused = false
                    document.commit(updatedMark(for: value, crop: crop, frame: frame, scale: scale), minimumDrag: 2 / scale)
                    copied = false
                })
            .accessibilityElement()
            .accessibilityLabel("截图编辑画布")
            .accessibilityIdentifier("local-screenshot-canvas")
        }
    }

    private func updatedMark(for gesture: DragGesture.Value, crop: CGRect, frame: CGRect, scale: CGFloat) -> ScreenshotMark {
        func pixel(_ point: CGPoint) -> CGPoint {
            CGPoint(x: min(crop.maxX, max(crop.minX, crop.minX + (point.x - frame.minX) / scale)),
                    y: min(crop.maxY, max(crop.minY, crop.minY + (point.y - frame.minY) / scale)))
        }
        let start = pixel(gesture.startLocation)
        let end = pixel(gesture.location)
        var mark = draft ?? ScreenshotMark(tool: tool, start: start, end: start, color: NSColor(color).cgColor, width: max(1, 3 / scale))
        mark.end = end
        if mark.tool == .text {
            mark.text = annotation.trimmingCharacters(in: .whitespacesAndNewlines)
            // Leave room for a line even when the click lands at the bottom or right edge.
            let inset = mark.width * 7
            mark.end = CGPoint(x: min(end.x, max(crop.minX, crop.maxX - inset)),
                               y: min(end.y, max(crop.minY, crop.maxY - inset)))
            mark.textArea = CGSize(width: crop.maxX - mark.end.x, height: crop.maxY - mark.end.y)
        }
        if mark.tool == .pen, end != (mark.points.last ?? start) { mark.points.append(end) }
        return mark
    }
}
