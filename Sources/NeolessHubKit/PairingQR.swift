import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The pairing link as a QR code: a PNG for the iPhone camera, and the same code drawn in the terminal.
public enum PairingQR {
    /// Light modules around the code, as the QR standard asks.
    static let quietZone = 4

    public enum Failure: LocalizedError {
        case generate, write(String)
        public var errorDescription: String? {
            switch self {
            case .generate: return "二维码生成失败"
            case .write(let path): return "二维码没能保存到 \(path)"
            }
        }
    }

    /// The modules of the QR code for `text`, row by row (true = dark), without the quiet zone.
    public static func modules(for text: String) throws -> [[Bool]] {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { throw Failure.generate }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage else { throw Failure.generate }
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, height > 0,
              let cgImage = CIContext(options: [.useSoftwareRenderer: true]).createCGImage(image, from: extent),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { throw Failure.generate }
        context.interpolationQuality = .none
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { throw Failure.generate }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height)
        // The bitmap's first row is the image's top row.
        var rows = (0..<height).map { y in (0..<width).map { x in pixels[y * width + x] < 128 } }
        // CIQRCodeGenerator adds a light margin of its own: drop it, `quietZone` is added back.
        while let first = rows.first, !first.contains(true) { rows.removeFirst() }
        while let last = rows.last, !last.contains(true) { rows.removeLast() }
        let left = rows.map { $0.firstIndex(of: true) ?? Int.max }.min() ?? 0
        let right = rows.map { $0.lastIndex(of: true) ?? -1 }.max() ?? -1
        guard !rows.isEmpty, left <= right else { throw Failure.generate }
        return rows.map { Array($0[left...right]) }
    }

    /// PNG, `scale` pixels per module, black on white with the quiet zone.
    public static func png(for text: String, scale: Int = 12) throws -> Data {
        let grid = try modules(for: text)
        let size = (grid.count + 2 * quietZone) * scale
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { throw Failure.generate }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(gray: 0, alpha: 1)
        for (row, line) in grid.enumerated() {
            for (column, dark) in line.enumerated() where dark {
                // Core Graphics counts rows from the bottom.
                let y = size - (row + quietZone + 1) * scale
                context.fill(CGRect(x: (column + quietZone) * scale, y: y, width: scale, height: scale))
            }
        }
        guard let image = context.makeImage() else { throw Failure.generate }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure.generate
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.generate }
        return out as Data
    }

    /// Writes the PNG readable by its owner only (0600) from the start: it carries a device token. Written to a
    /// new file next to `url`, then renamed over it.
    public static func writePNG(for text: String, to url: URL) throws {
        let data = try png(for: text)
        guard PrivateFile.write(data, to: url) else { throw Failure.write(url.path) }
    }

    /// The code for a terminal: two module rows per line with half blocks, colours set explicitly (black on
    /// white) so it scans on dark and light terminal themes alike.
    public static func terminal(for text: String) throws -> String {
        let grid = try modules(for: text)
        let width = grid.first?.count ?? 0
        let blank = [Bool](repeating: false, count: width + 2 * quietZone)
        let padded = Array(repeating: blank, count: quietZone)
            + grid.map { Array(repeating: false, count: quietZone) + $0 + Array(repeating: false, count: quietZone) }
            + Array(repeating: blank, count: quietZone + 1)
        let black = 16, white = 231
        var lines: [String] = []
        var row = 0
        while row + 1 < padded.count {
            var line = ""
            for column in 0..<padded[row].count {
                let top = padded[row][column] ? black : white
                let bottom = padded[row + 1][column] ? black : white
                line += "\u{1B}[38;5;\(top)m\u{1B}[48;5;\(bottom)m▀"
            }
            lines.append(line + "\u{1B}[0m")
            row += 2
        }
        return lines.joined(separator: "\n")
    }
}
