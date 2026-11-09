import AppKit
import SwiftUI
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import CoreText

enum HUDContrastStatus: Equatable {
    case off, checking, active, permissionRequired, unavailable
    var label: String {
        switch self {
        case .off: return "Automatic contrast off"
        case .checking: return "Checking background…"
        case .active: return "Automatic contrast on"
        case .permissionRequired: return "Screen access required"
        case .unavailable: return "Background access unavailable; retrying"
        }
    }
}

struct HUDContrastUnit: Equatable {
    let id: String
    let rect: CGRect
    var text: HUDInkText? = nil
    var revision: Int = 0
    var stencil: HUDInkStencil = .rendered
    var layer: Int = 0
}

enum HUDInkStencil: Equatable {
    case rendered, cross, circle, diamond(CGFloat)
    func alpha(width: Int, height: Int, sx: CGFloat, sy: CGFloat) -> [UInt8]? {
        guard self != .rendered else { return nil }
        var alpha = [UInt8](repeating: 0, count: width * height)
        alpha.withUnsafeMutableBytes { pixels in
            guard let context = CGContext(data: pixels.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.scaleBy(x: sx, y: sy)
            let bounds = CGRect(x: 0, y: 0, width: CGFloat(width) / sx, height: CGFloat(height) / sy)
            context.setStrokeColor(gray: 1, alpha: 1); context.setLineWidth(1)
            switch self {
            case .rendered: break
            case .cross:
                context.move(to: CGPoint(x: bounds.midX - 2.5, y: bounds.midY)); context.addLine(to: CGPoint(x: bounds.midX + 2.5, y: bounds.midY))
                context.move(to: CGPoint(x: bounds.midX, y: bounds.midY - 2.5)); context.addLine(to: CGPoint(x: bounds.midX, y: bounds.midY + 2.5)); context.strokePath()
            case .circle:
                context.strokeEllipse(in: CGRect(x: bounds.midX - 1.5, y: bounds.midY - 1.5, width: 3, height: 3))
            case .diamond(let diameter):
                let rect = CGRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2, width: diameter, height: diameter)
                let path = CGMutablePath(); path.move(to: CGPoint(x: rect.midX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)); path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.midY)); path.closeSubpath()
                context.addPath(path); context.clip(); context.addPath(path); context.setLineWidth(HUDStyle.stroke * 2); context.strokePath()
            }
        }
        return alpha
    }
}

struct HUDInkText: Equatable {
    enum Design: Equatable { case system, monospaced, digits }
    let value: String
    var size: CGFloat
    var weight: CGFloat = NSFont.Weight.regular.rawValue
    var design: Design = .system
    var tracking: CGFloat = 0
    var insetX: CGFloat = 0
    var maxLines: Int = 1
    var trailingSymbol: String? = nil
    var font: NSFont {
        let weight = NSFont.Weight(rawValue: weight)
        switch design {
        case .system: return .systemFont(ofSize: size, weight: weight)
        case .monospaced: return .monospacedSystemFont(ofSize: size, weight: weight)
        case .digits: return .monospacedDigitSystemFont(ofSize: size, weight: weight)
        }
    }
    /// CoreText supplies character advances; actual rendered alpha supplies the sampling pixels.
    func characters(in bounds: CGRect, id: String) -> [(String, CGRect)] {
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        if tracking != 0 { attributes[.kern] = tracking }
        let attributed = NSAttributedString(string: value, attributes: attributes)
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let trailingWidth = trailingSymbol.map { CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: [.font: font])), nil, nil, nil)) } ?? 0
        let length = attributed.length, available = max(1, bounds.width - insetX - (trailingWidth > 0 ? trailingWidth + 3 : 0))
        var lines: [(CTLine, CFRange)] = [], start = 0
        while start < length && lines.count < maxLines {
            let count = maxLines == 1 ? length : max(1, CTTypesetterSuggestLineBreak(typesetter, start, Double(available)))
            let range = CFRange(location: start, length: min(count, length - start))
            lines.append((CTTypesetterCreateLine(typesetter, range), range)); start += range.length
        }
        var result: [(String, CGRect)] = [], offset = 0
        let ranges = value.map { character -> (String, NSRange) in
            let string = String(character), range = NSRange(location: offset, length: string.utf16.count)
            offset += range.length; return (string, range)
        }
        for (row, pair) in lines.enumerated() {
            let (line, range) = pair
            let natural = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let scale = min(1, available / max(1, natural))
            let rowHeight = bounds.height / CGFloat(max(1, lines.count))
            for (character, characterRange) in ranges where characterRange.location >= range.location && characterRange.location < range.location + range.length {
                guard !character.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let a = CTLineGetOffsetForStringIndex(line, characterRange.location, nil)
                let b = CTLineGetOffsetForStringIndex(line, characterRange.location + characterRange.length, nil)
                guard b > a else { continue }
                result.append(("\(id):\(characterRange.location)", CGRect(x: bounds.minX + insetX + a * scale,
                    y: bounds.minY + CGFloat(row) * rowHeight, width: (b - a) * scale, height: rowHeight)))
            }
        }
        if trailingWidth > 0 {
            result.append(("\(id):trailing", CGRect(x: bounds.maxX - trailingWidth, y: bounds.minY, width: trailingWidth, height: bounds.height)))
        }
        return result
    }
}

/// Cached ink coverage from this app's own transparent view, never from the desktop.
struct HUDInkAtlas: Equatable {
    struct Unit: Equatable {
        let id: String
        let rect: CGRect
        let pixels: [Int]
        let weights: [UInt8]
        var outputPixels: [Int] = []
    }
    let width: Int
    let height: Int
    let units: [Unit]
    static func make(bitmap: NSBitmapImageRep, pointSize: CGSize, units: [HUDContrastUnit]) -> HUDInkAtlas {
        let width = bitmap.pixelsWide, height = bitmap.pixelsHigh
        guard let data = bitmap.bitmapData, bitmap.samplesPerPixel == 4, pointSize.width > 0, pointSize.height > 0 else {
            return HUDInkAtlas(width: width, height: height, units: [])
        }
        let sx = CGFloat(width) / pointSize.width, sy = CGFloat(height) / pointSize.height
        var result: [Unit] = [], coverage: [[Int]] = []
        for unit in units.sorted(by: { $0.layer == $1.layer ? $0.id < $1.id : $0.layer < $1.layer }) {
            if case .diamond = unit.stencil, unit.revision == 0 { continue }
            let cells = unit.text?.characters(in: unit.rect, id: unit.id) ?? [(unit.id, unit.rect)]
            for (id, cell) in cells {
                // Adjacent text cells share a rounded boundary, so no character gets split colors.
                let left = max(0, min(width, Int((cell.minX * sx).rounded())))
                let right = max(left, min(width, Int((cell.maxX * sx).rounded())))
                let top = max(0, min(height, Int(floor(cell.minY * sy))))
                let bottom = max(top, min(height, Int(ceil(cell.maxY * sy))))
                var pixels: [Int] = [], weights: [UInt8] = []
                guard right > left, bottom > top else { continue }
                let isolated = unit.stencil.alpha(width: right - left, height: bottom - top, sx: sx, sy: sy)
                var output: [Int] = []
                for y in top..<bottom { for x in left..<right {
                    let ownAlpha = isolated?[(y - top) * (right - left) + x - left] ?? 255
                    let alpha = min(data[y * bitmap.bytesPerRow + x * 4 + 3], ownAlpha)
                    if ownAlpha > 0 { output.append(y * width + x) }
                    // Ignore hit planes, faint empty-bar fills, and shadow fringes.
                    if alpha >= 48 { pixels.append(y * width + x); weights.append(alpha) }
                } }
                guard !pixels.isEmpty else { continue }
                result.append(Unit(id: id, rect: CGRect(x: left, y: top, width: right - left, height: bottom - top), pixels: pixels, weights: weights))
                coverage.append(output)
            }
        }
        // Preserve draw order where entities overlap, e.g. a hollow diamond above the reference bar.
        var owners = [Int](repeating: -1, count: width * height)
        for (index, pixels) in coverage.enumerated() { for pixel in pixels { owners[pixel] = index } }
        result = result.enumerated().map { index, unit in
            let samples = zip(unit.pixels, unit.weights).filter { owners[$0.0] == index }
            return Unit(id: unit.id, rect: unit.rect, pixels: samples.map { $0.0 }, weights: samples.map { $0.1 },
                outputPixels: coverage[index].filter { owners[$0] == index })
        }.filter { !$0.pixels.isEmpty }
        return HUDInkAtlas(width: width, height: height, units: result)
    }
}

/// Stores only a one-bit light/dark decision per background pixel.
struct HUDContrastMask {
    private(set) var decisions: [UInt8] = []
    private(set) var width = 0
    private(set) var height = 0
    private var unitGeometry: [HUDContrastUnit] = []
    private var unitPointSize = CGSize.zero
    private var compiledUnits: [HUDContrastUnit] = []
    private var unitStates: [String: Bool] = [:]
    private var inkAtlas: HUDInkAtlas?
    private var inkStride = 0
    private var inkSamples: [[(Int, Double)]] = []
    private static let linear = (0...255).map { value -> Double in
        let v = Double(value) / 255
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    private static func toneLuminance(_ color: Color) -> Double {
        let rgb = NSColor(color).usingColorSpace(.sRGB)!
        func channel(_ value: CGFloat) -> Double {
            let v = Double(value); return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(rgb.redComponent) + 0.7152 * channel(rgb.greenComponent) + 0.0722 * channel(rgb.blueComponent)
    }
    /// Compare contrast at every ink pixel; averaging luminance would let white gaps dominate dark text.
    private static let contrastPreference: [Double] = {
        let light = toneLuminance(MiniPalette.hudGreen), dark = toneLuminance(MiniPalette.hudDarkGreen)
        return (0..<1024).map { index in
            let background = Double(index) / 1023
            func ratio(_ tone: Double) -> Double { (max(tone, background) + 0.05) / (min(tone, background) + 0.05) }
            return log(ratio(light)) - log(ratio(dark))
        }
    }()
    static func inkUsesDark(preference: Double, previous: Bool?) -> Bool {
        if previous == true { return preference <= 0.10 }
        if previous == false { return preference < -0.10 }
        return preference < 0
    }
    static func useDark(luminance: Double, previous: Bool?) -> Bool {
        if previous == true { return luminance > 0.14 }
        if previous == false { return luminance >= 0.20 }
        return luminance >= 0.17
    }
    /// Sample only covered glyph/symbol pixels, then choose one tone for the whole entity.
    mutating func updateInkBGRA(_ base: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int, atlas: HUDInkAtlas) -> Bool {
        guard width == atlas.width, height == atlas.height, width > 0, bytesPerRow >= width * 4 else { return false }
        let changedGeometry = inkAtlas != atlas || self.width != width || self.height != height || inkStride != bytesPerRow
        if changedGeometry {
            self.width = width; self.height = height; inkAtlas = atlas; inkStride = bytesPerRow
            inkSamples = atlas.units.map { unit in
                let total = max(1, unit.weights.reduce(0) { $0 + Int($1) })
                return zip(unit.pixels, unit.weights).map { index, weight in
                    ((index / width) * bytesPerRow + (index % width) * 4, Double(weight) / Double(total))
                }
            }
            let ids = Set(atlas.units.map(\.id)); unitStates = unitStates.filter { ids.contains($0.key) }
        }
        var changed = changedGeometry
        for (index, unit) in atlas.units.enumerated() {
            var preference = 0.0
            for (offset, weight) in inkSamples[index] {
                let luminance = 0.2126 * Self.linear[Int(base[offset + 2])] + 0.7152 * Self.linear[Int(base[offset + 1])] + 0.0722 * Self.linear[Int(base[offset])]
                preference += weight * Self.contrastPreference[min(1023, max(0, Int(luminance * 1023)))]
            }
            let dark = Self.inkUsesDark(preference: preference, previous: unitStates[unit.id])
            if unitStates[unit.id] != dark { unitStates[unit.id] = dark; changed = true }
        }
        guard changed else { return false }
        decisions = [UInt8](repeating: 0, count: width * height)
        decisions.withUnsafeMutableBufferPointer { output in
            for unit in atlas.units where unitStates[unit.id] == true {
                for pixel in unit.outputPixels { output[pixel] = 1 }
            }
        }
        return true
    }
    /// A unit gets one tone from its whole background, so text and instrument strokes never split.
    mutating func updateGroupedBGRA(_ base: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int,
                                   pointSize: CGSize, units: [HUDContrastUnit]) -> Bool {
        guard width > 0, height > 0, bytesPerRow >= width * 4, pointSize.width > 0, pointSize.height > 0, !units.isEmpty else { return false }
        let geometryChanged = self.width != width || self.height != height || unitGeometry != units || unitPointSize != pointSize
        if geometryChanged {
            self.width = width; self.height = height; unitGeometry = units; unitPointSize = pointSize
            compiledUnits = Self.mergedUnits(units, within: CGRect(origin: .zero, size: pointSize)).map { unit in
                let sx = CGFloat(width) / pointSize.width, sy = CGFloat(height) / pointSize.height
                let left = max(0, floor(unit.rect.minX * sx)), top = max(0, floor(unit.rect.minY * sy))
                let right = min(CGFloat(width), ceil(unit.rect.maxX * sx)), bottom = min(CGFloat(height), ceil(unit.rect.maxY * sy))
                return HUDContrastUnit(id: unit.id, rect: CGRect(x: left, y: top, width: right - left, height: bottom - top))
            }
            unitStates.removeAll()
        }
        var changed = geometryChanged
        for unit in compiledUnits {
            let left = Int(unit.rect.minX), right = Int(unit.rect.maxX), top = Int(unit.rect.minY), bottom = Int(unit.rect.maxY)
            guard right > left, bottom > top else { continue }
            var total = 0.0
            for y in top..<bottom {
                let row = base.advanced(by: y * bytesPerRow)
                for x in left..<right {
                    let pixel = x * 4
                    total += 0.2126 * Self.linear[Int(row[pixel + 2])] + 0.7152 * Self.linear[Int(row[pixel + 1])] + 0.0722 * Self.linear[Int(row[pixel])]
                }
            }
            let dark = Self.useDark(luminance: total / Double((right - left) * (bottom - top)), previous: unitStates[unit.id])
            if unitStates[unit.id] != dark { unitStates[unit.id] = dark; changed = true }
        }
        guard changed else { return false }
        decisions = [UInt8](repeating: 0, count: width * height)
        let fills = compiledUnits.filter { unitStates[$0.id] == true }
        decisions.withUnsafeMutableBufferPointer { pixels in
            for unit in fills {
                for row in Int(unit.rect.minY)..<Int(unit.rect.maxY) {
                    memset(pixels.baseAddress!.advanced(by: row * width + Int(unit.rect.minX)), 1, Int(unit.rect.width))
                }
            }
        }
        return true
    }
    private static func mergedUnits(_ units: [HUDContrastUnit], within bounds: CGRect) -> [HUDContrastUnit] {
        var result: [HUDContrastUnit] = []
        for unit in units.sorted(by: { $0.id < $1.id }) {
            var rect = unit.rect.intersection(bounds), ids = [unit.id]
            guard !rect.isNull, !rect.isEmpty else { continue }
            while let index = result.firstIndex(where: {
                let overlap = $0.rect.intersection(rect)
                return !overlap.isNull && overlap.width > 0 && overlap.height > 0
            }) {
                let previous = result.remove(at: index)
                rect = rect.union(previous.rect); ids.append(previous.id)
            }
            result.append(HUDContrastUnit(id: ids.sorted().joined(separator: "|"), rect: rect))
        }
        return result
    }
    /// Reads the capture surface directly, with no CGImage/RGBA copy or allocation on unchanged frames.
    mutating func updateBGRA(_ base: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int) -> Bool {
        guard width > 0, height > 0, bytesPerRow >= width * 4 else { return false }
        var changed = self.width != width || self.height != height
        if changed { self.width = width; self.height = height; decisions = [UInt8](repeating: 2, count: width * height) }
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow)
            for x in 0..<width {
                let pixel = x * 4, index = y * width + x, old = decisions[index]
                let luminance = 0.2126 * Self.linear[Int(row[pixel + 2])] + 0.7152 * Self.linear[Int(row[pixel + 1])] + 0.0722 * Self.linear[Int(row[pixel])]
                let next: UInt8 = Self.useDark(luminance: luminance, previous: old == 2 ? nil : old == 1) ? 1 : 0
                if next != old { decisions[index] = next; changed = true }
            }
        }
        return changed
    }
    mutating func update(rgba: [UInt8], width: Int, height: Int, pointSize: NSSize) -> NSImage? {
        guard width > 0, height > 0, rgba.count == width * height * 4 else { return nil }
        let old = self.width == width && self.height == height ? decisions : []
        var next = [UInt8](repeating: 0, count: width * height)
        for index in next.indices {
            let pixel = index * 4
            let y = 0.2126 * Self.linear[Int(rgba[pixel])] + 0.7152 * Self.linear[Int(rgba[pixel + 1])] + 0.0722 * Self.linear[Int(rgba[pixel + 2])]
            next[index] = Self.useDark(luminance: y, previous: old.isEmpty ? nil : old[index] == 1) ? 1 : 0
        }
        guard next != old || self.width != width || self.height != height else { return nil }
        self.width = width; self.height = height; decisions = next
        return image(pointSize: pointSize)
    }
    func image(pointSize: NSSize) -> NSImage? {
        guard width > 0, height > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32),
              let data = bitmap.bitmapData else { return nil }
        let color = NSColor(MiniPalette.hudDarkGreen).usingColorSpace(.deviceRGB)!
        let rgb = [color.redComponent, color.greenComponent, color.blueComponent].map { UInt8(($0 * 255).rounded()) }
        for index in decisions.indices {
            let pixel = index * 4
            let dark = decisions[index] == 1
            data[pixel] = dark ? rgb[0] : 0; data[pixel + 1] = dark ? rgb[1] : 0
            data[pixel + 2] = dark ? rgb[2] : 0; data[pixel + 3] = dark ? 255 : 0
        }
        bitmap.size = pointSize
        let image = NSImage(size: pointSize); image.addRepresentation(bitmap); image.isTemplate = false
        return image
    }
    static func rgba(_ image: CGImage) -> [UInt8]? {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let success = bytes.withUnsafeMutableBytes { data -> Bool in
            guard let context = CGContext(data: data.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return success ? bytes : nil
    }
    static func selfTest() {
        let inkBitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 32, bitsPerPixel: 32)!
        memset(inkBitmap.bitmapData!, 0, inkBitmap.bytesPerRow * 2)
        for pixel in [0, 4] { inkBitmap.bitmapData![pixel * 4 + 3] = 255 }
        let ink = HUDInkAtlas.make(bitmap: inkBitmap, pointSize: CGSize(width: 8, height: 2), units: [
            HUDContrastUnit(id: "letter-C", rect: CGRect(x: 0, y: 0, width: 4, height: 2)),
            HUDContrastUnit(id: "letter-o", rect: CGRect(x: 4, y: 0, width: 4, height: 2))])
        precondition(ink.units.map(\.pixels) == [[0], [4]], "Blank glyph space must not enter the sample set")
        var inkBackground = [UInt8](repeating: 255, count: 64), inkMask = HUDContrastMask()
        for pixel in [0, 4] { for channel in 0..<3 { inkBackground[pixel * 4 + channel] = 0 } }
        inkBackground.withUnsafeBufferPointer { p in
            precondition(inkMask.updateInkBGRA(p.baseAddress!, width: 8, height: 2, bytesPerRow: 32, atlas: ink))
        }
        precondition(inkMask.decisions.allSatisfy { $0 == 0 }, "Bright empty space must not darken a glyph over dark ink-position pixels")
        inkBackground[0] = 255; inkBackground[1] = 255; inkBackground[2] = 255
        inkBackground.withUnsafeBufferPointer { p in
            precondition(inkMask.updateInkBGRA(p.baseAddress!, width: 8, height: 2, bytesPerRow: 32, atlas: ink))
        }
        precondition(inkMask.decisions == [1,1,1,1,0,0,0,0,1,1,1,1,0,0,0,0], "Each letter must switch as one entity, independently of its neighbor")
        let mixedInk = HUDInkAtlas(width: 5, height: 1, units: [HUDInkAtlas.Unit(id: "mixed-letter", rect: CGRect(x: 0, y: 0, width: 5, height: 1),
            pixels: Array(0..<5), weights: [255,255,255,255,255], outputPixels: Array(0..<5))])
        var mixedPixels: [UInt8] = [0,0,0,255, 0,0,0,255, 0,0,0,255, 255,255,255,255, 255,255,255,255]
        var mixedMask = HUDContrastMask()
        mixedPixels.withUnsafeBufferPointer { p in
            precondition(mixedMask.updateInkBGRA(p.baseAddress!, width: 5, height: 1, bytesPerRow: 20, atlas: mixedInk))
        }
        precondition(mixedMask.decisions == [0,0,0,0,0], "A letter mostly over black text should prefer bright green despite some white background")
        for pixel in 0..<5 { for channel in 0..<3 { mixedPixels[pixel * 4 + channel] = 255 - mixedPixels[pixel * 4 + channel] } }
        mixedPixels.withUnsafeBufferPointer { p in
            precondition(mixedMask.updateInkBGRA(p.baseAddress!, width: 5, height: 1, bytesPerRow: 20, atlas: mixedInk))
        }
        precondition(mixedMask.decisions == [1,1,1,1,1], "A letter mostly over white should switch back as a whole entity")
        let symbolBitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 20,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 80, bitsPerPixel: 32)!
        memset(symbolBitmap.bitmapData!, 0, symbolBitmap.bytesPerRow * 20)
        let diamondAlpha = HUDInkStencil.diamond(10).alpha(width: 20, height: 20, sx: 2, sy: 2)!
        for pixel in 0..<400 { symbolBitmap.bitmapData![pixel * 4 + 3] = (pixel / 20 == 9 || pixel / 20 == 10) ? 255 : diamondAlpha[pixel] }
        let overlapping = HUDInkAtlas.make(bitmap: symbolBitmap, pointSize: CGSize(width: 10, height: 10), units: [
            HUDContrastUnit(id: "reference", rect: CGRect(x: 0, y: 4.5, width: 10, height: 1)),
            HUDContrastUnit(id: "diamond", rect: CGRect(x: 0, y: 0, width: 10, height: 10), revision: 1, stencil: .diamond(10), layer: 2)])
        let diamond = overlapping.units.first { $0.id == "diamond" }!, reference = overlapping.units.first { $0.id == "reference" }!
        precondition(!diamond.pixels.contains(210) && reference.pixels.contains(210), "A hollow diamond must not sample or recolor the reference through its empty center")
        precondition(Set(diamond.outputPixels).isDisjoint(with: reference.outputPixels), "Overlapping symbols must retain distinct visible pixels")
        var grouped = HUDContrastMask()
        let units = [HUDContrastUnit(id: "word", rect: CGRect(x: 0, y: 0, width: 4, height: 2)),
                     HUDContrastUnit(id: "instrument", rect: CGRect(x: 4, y: 0, width: 4, height: 2))]
        var pattern = [UInt8](repeating: 0, count: 8 * 2 * 4)
        for y in 0..<2 { for x in 0..<8 {
            let pixel = (y * 8 + x) * 4, value: UInt8 = x < 4 && x % 2 == 1 ? 255 : 0
            pattern[pixel] = value; pattern[pixel + 1] = value; pattern[pixel + 2] = value; pattern[pixel + 3] = 255
        } }
        pattern.withUnsafeBufferPointer { pixels in
            precondition(grouped.updateGroupedBGRA(pixels.baseAddress!, width: 8, height: 2, bytesPerRow: 32,
                                                   pointSize: CGSize(width: 8, height: 2), units: units))
        }
        precondition(grouped.decisions == [1,1,1,1,0,0,0,0, 1,1,1,1,0,0,0,0], "A patterned word background must still produce one solid word tone")
        for y in 0..<2 { for x in 0..<4 {
            let pixel = (y * 8 + x) * 4, value: UInt8 = x % 2 == 0 ? 255 : 0
            pattern[pixel] = value; pattern[pixel + 1] = value; pattern[pixel + 2] = value
        } }
        pattern.withUnsafeBufferPointer { pixels in
            precondition(!grouped.updateGroupedBGRA(pixels.baseAddress!, width: 8, height: 2, bytesPerRow: 32,
                                                    pointSize: CGSize(width: 8, height: 2), units: units), "Texture movement without a tone change must not redraw the HUD")
        }
        var mask = HUDContrastMask()
        let rgba: [UInt8] = [0,0,0,255, 0,0,0,255, 255,255,255,255, 255,255,255,255]
        precondition(mask.update(rgba: rgba, width: 4, height: 1, pointSize: NSSize(width: 4, height: 1)) != nil)
        precondition(mask.decisions == [0,0,1,1])
        precondition(mask.update(rgba: rgba, width: 4, height: 1, pointSize: NSSize(width: 4, height: 1)) == nil)
        var streamed = HUDContrastMask()
        rgba.withUnsafeBufferPointer { pixels in
            precondition(streamed.updateBGRA(pixels.baseAddress!, width: 4, height: 1, bytesPerRow: 16))
            precondition(!streamed.updateBGRA(pixels.baseAddress!, width: 4, height: 1, bytesPerRow: 16))
        }
        precondition(streamed.decisions == mask.decisions)
        var padded = HUDContrastMask()
        let blueThenRed: [UInt8] = [255,0,0,255, 42,42,42,42, 0,0,255,255, 42,42,42,42]
        blueThenRed.withUnsafeBufferPointer { pixels in
            precondition(padded.updateBGRA(pixels.baseAddress!, width: 1, height: 2, bytesPerRow: 8))
        }
        precondition(padded.decisions == [0,1], "BGRA channels and padded row strides must match the captured pixels")
        precondition(!useDark(luminance: 0.18, previous: false) && useDark(luminance: 0.18, previous: true))
        precondition(useDark(luminance: 0.21, previous: false) && !useDark(luminance: 0.13, previous: true))
        let rows: [UInt8] = [255,255,255,255, 0,0,0,255, 0,0,0,255, 0,0,0,255]
        let provider = CGDataProvider(data: Data(rows) as CFData)!
        let fixture = CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        precondition(Self.rgba(fixture) == rows, "Captured pixel rows must not flip vertically")
        let converted = HUDCaptureRegion.quartzRect(NSRect(x: -100, y: 900, width: 110, height: 148), desktopTop: 1000)
        precondition(converted == CGRect(x: -100, y: -48, width: 110, height: 148))
    }
}

enum HUDContrastTarget: Hashable { case mini }
struct HUDCaptureRegion {
    let target: HUDContrastTarget
    let frame: NSRect
    let scale: CGFloat
    static func quartzRect(_ rect: NSRect, desktopTop: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: desktopTop - rect.maxY, width: rect.width, height: rect.height)
    }
}


/// A serial worker processes only new screen frames and publishes only changed tone masks.
private final class HUDContrastStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "io.github.brianbrianoh.usage-gauge.contrast", qos: .userInteractive)
    var onFrame: ((HUDContrastMask, HUDCaptureRegion, Int, Int) -> Void)?
    var onStop: ((SCStream, Error) -> Void)?
    private var region: HUDCaptureRegion?
    private var generation = 0
    private var minimumTime = CMTime.zero
    private var mask = HUDContrastMask()
    private var atlas: HUDInkAtlas?
    private var inkRevision = 0
    private var lastPixels: CVPixelBuffer?
    func pause() { queue.async { self.region = nil; self.lastPixels = nil } }
    func setInkAtlas(_ atlas: HUDInkAtlas, revision: Int) {
        queue.async {
            self.atlas = atlas; self.inkRevision = revision
            if let pixels = self.lastPixels, let region = self.region { self.process(pixels, region: region) }
        }
    }
    func configure(_ region: HUDCaptureRegion, generation: Int) {
        let timestamp = CMClockGetTime(CMClockGetHostTimeClock())
        queue.async {
            self.region = region; self.generation = generation; self.minimumTime = timestamp
            self.mask = HUDContrastMask(); self.lastPixels = nil
        }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let region, CMSampleBufferIsValid(sampleBuffer),
              CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sampleBuffer), minimumTime) >= 0,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              rawStatus == SCFrameStatus.complete.rawValue || rawStatus == SCFrameStatus.started.rawValue,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer),
              CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA else { return }
        lastPixels = pixels
        process(pixels, region: region)
    }
    private func process(_ pixels: CVPixelBuffer, region: HUDCaptureRegion) {
        guard let atlas else { return }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels)?.assumingMemoryBound(to: UInt8.self) else { return }
        let changed = mask.updateInkBGRA(base, width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels),
                                       bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), atlas: atlas)
        if changed { onFrame?(mask, region, generation, inkRevision) }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { onStop?(stream, error) }
}

/// One small, cursor-free, audio-free mini-HUD stream; no timer screenshots or status-item sampling.
@MainActor final class HUDContrastController {
    static let framesPerSecond: Int32 = 30
    private let regions: () -> [HUDCaptureRegion]
    private let onMask: (HUDContrastTarget, NSImage?) -> Void
    private let onStatus: (HUDContrastStatus) -> Void
    private let onUserStop: () -> Void
    private var enabled = false
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var taskID: UUID?
    private var needsRefresh = false
    private var generation = 0
    private var requestedPermission = false
    private var status = HUDContrastStatus.off
    private var content: SCShareableContent?
    private var stream: SCStream?
    private var output: HUDContrastStreamOutput?
    private var currentRegion: HUDCaptureRegion?
    private var currentDisplay: CGDirectDisplayID?
    private var retryAfter = Date.distantPast
    private var atlas: HUDInkAtlas?
    private var inkRevision = 0

    init(regions: @escaping () -> [HUDCaptureRegion],
         onMask: @escaping (HUDContrastTarget, NSImage?) -> Void,
         onStatus: @escaping (HUDContrastStatus) -> Void,
         onUserStop: @escaping () -> Void) {
        self.regions = regions; self.onMask = onMask; self.onStatus = onStatus; self.onUserStop = onUserStop
    }
    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        enabled = value; generation += 1
        timer?.invalidate(); timer = nil; task?.cancel(); task = nil; taskID = nil
        stopStream(); onMask(.mini, nil)
        guard enabled else { setStatus(.off); return }
        setStatus(.checking)
        // A cheap watchdog only reconnects after permission/display changes. Frames drive all color updates.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }
    func stop() { setEnabled(false) }
    func setInkAtlas(_ value: HUDInkAtlas) {
        guard value != atlas else { return }
        atlas = value; inkRevision += 1; output?.setInkAtlas(value, revision: inkRevision)
    }
    func geometryChanged(_ target: HUDContrastTarget? = nil) {
        generation += 1; currentRegion = nil; output?.pause(); onMask(.mini, nil)
        if target == nil { content = nil; currentDisplay = nil }
        refresh()
    }
    func requestPermission(openSettingsIfNeeded: Bool = true) {
        requestedPermission = true
        if CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() {
            content = nil; retryAfter = .distantPast; refresh()
        } else {
            setStatus(.permissionRequired)
            if openSettingsIfNeeded, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }
    private func stopStream() {
        output?.pause()
        if let stream { Task { try? await stream.stopCapture() } }
        stream = nil; output = nil; currentRegion = nil; currentDisplay = nil
    }
    private func setStatus(_ value: HUDContrastStatus) {
        guard status != value else { return }; status = value; onStatus(value)
    }
    private func refresh() {
        guard enabled, Date() >= retryAfter else { return }
        guard let requested = regions().first else { return }
        if stream != nil, currentRegion?.frame == requested.frame, currentRegion?.scale == requested.scale { return }
        guard task == nil else { needsRefresh = true; return }
        guard CGPreflightScreenCaptureAccess() else {
            setStatus(.permissionRequired)
            if !requestedPermission {
                requestedPermission = true
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.enabled else { return }; self.requestPermission(openSettingsIfNeeded: false)
                }
            }
            return
        }
        let identifier = UUID(), token = generation
        taskID = identifier
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.taskID == identifier {
                    self.task = nil; self.taskID = nil
                    if self.needsRefresh { self.needsRefresh = false; self.refresh() }
                }
            }
            do {
                if self.content == nil { self.content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
                guard let content = self.content, self.enabled, token == self.generation, !Task.isCancelled else { return }
                let rect = HUDCaptureRegion.quartzRect(requested.frame, desktopTop: NSScreen.screens.first?.frame.maxY ?? 0)
                // During a drag across display edges, wait for one display to contain the complete HUD.
                guard let display = content.displays.first(where: { $0.frame.contains(rect) }) else {
                    self.stopStream(); self.setStatus(.checking); return
                }
                let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                guard !ownApps.isEmpty else { throw CaptureFailure.ownApplicationMissing }
                let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
                if #available(macOS 14.2, *) { filter.includeMenuBar = true }
                let config = SCStreamConfiguration()
                config.sourceRect = CGRect(x: rect.minX - display.frame.minX, y: rect.minY - display.frame.minY, width: rect.width, height: rect.height)
                config.width = max(1, Int((rect.width * requested.scale).rounded()))
                config.height = max(1, Int((rect.height * requested.scale).rounded()))
                config.minimumFrameInterval = CMTime(value: 1, timescale: Self.framesPerSecond)
                config.queueDepth = 3; config.pixelFormat = kCVPixelFormatType_32BGRA
                config.colorSpaceName = CGColorSpace.sRGB
                config.scalesToFit = true; config.preservesAspectRatio = false
                config.showsCursor = false; config.capturesAudio = false
                if let stream = self.stream, let output = self.output {
                    output.pause()
                    if self.currentDisplay != display.displayID { try await stream.updateContentFilter(filter) }
                    try await stream.updateConfiguration(config)
                    guard self.enabled, token == self.generation, !Task.isCancelled else { return }
                    self.currentRegion = requested; self.currentDisplay = display.displayID
                    output.configure(requested, generation: token)
                } else {
                    let output = HUDContrastStreamOutput()
                    if let atlas = self.atlas { output.setInkAtlas(atlas, revision: self.inkRevision) }
                    output.onFrame = { [weak self] mask, region, token, inkToken in
                        Task { @MainActor in
                            guard let self, self.enabled, self.generation == token, self.inkRevision == inkToken,
                                  self.regions().first?.frame == region.frame,
                                  let image = mask.image(pointSize: region.frame.size) else { return }
                            self.onMask(.mini, image)
                        }
                    }
                    output.onStop = { [weak self] stopped, error in
                        Task { @MainActor in
                            guard let self, self.enabled, self.stream === stopped else { return }
                            self.stream = nil; self.output = nil; self.currentRegion = nil
                            self.onMask(.mini, nil)
                            if (error as NSError).code == -3817 { self.onUserStop(); return }
                            self.setStatus(CGPreflightScreenCaptureAccess() ? .unavailable : .permissionRequired)
                            self.retryAfter = Date().addingTimeInterval(2)
                        }
                    }
                    let stream = SCStream(filter: filter, configuration: config, delegate: output)
                    try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
                    output.configure(requested, generation: token)
                    self.stream = stream; self.output = output
                    try await stream.startCapture()
                    guard self.enabled, token == self.generation, !Task.isCancelled else { return }
                    self.currentRegion = requested; self.currentDisplay = display.displayID
                }
                self.setStatus(.active)
            } catch {
                guard self.enabled, token == self.generation, !Task.isCancelled else { return }
                self.stopStream(); self.onMask(.mini, nil); self.content = nil
                self.setStatus(CGPreflightScreenCaptureAccess() ? .unavailable : .permissionRequired)
                self.retryAfter = Date().addingTimeInterval(2)
            }
        }
    }
    private enum CaptureFailure: Error { case ownApplicationMissing }
}
