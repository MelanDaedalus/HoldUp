import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let target = URL(fileURLWithPath: CommandLine.arguments[1])

func draw(size: Int) throws -> Data {
    let color = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                  space: color, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw CocoaError(.fileWriteUnknown)
    }
    let scale = CGFloat(size) / 256
    context.scaleBy(x: scale, y: scale)
    let square = CGPath(roundedRect: CGRect(x: 18, y: 18, width: 220, height: 220),
                        cornerWidth: 53, cornerHeight: 53, transform: nil)
    context.addPath(square)
    context.setFillColor(red: 0.51, green: 0.36, blue: 0.82, alpha: 1)
    context.fillPath()

    context.setStrokeColor(red: 0.97, green: 0.94, blue: 1, alpha: 1)
    context.setLineWidth(11)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    for points in [
        [CGPoint(x: 66, y: 155), CGPoint(x: 66, y: 187), CGPoint(x: 98, y: 187)],
        [CGPoint(x: 156, y: 187), CGPoint(x: 188, y: 187), CGPoint(x: 188, y: 155)],
        [CGPoint(x: 188, y: 101), CGPoint(x: 188, y: 69), CGPoint(x: 156, y: 69)],
        [CGPoint(x: 98, y: 69), CGPoint(x: 66, y: 69), CGPoint(x: 66, y: 101)],
        [CGPoint(x: 95, y: 131), CGPoint(x: 119, y: 107), CGPoint(x: 161, y: 151)]
    ] {
        context.addLines(between: points)
        context.strokePath()
    }
    let png = NSMutableData()
    guard let image = context.makeImage(),
          let writer = CGImageDestinationCreateWithData(png as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(writer, image, nil)
    guard CGImageDestinationFinalize(writer) else { throw CocoaError(.fileWriteUnknown) }
    return png as Data
}

func chunk(_ type: String, _ payload: Data) -> Data {
    var output = Data(type.utf8)
    var length = UInt32(payload.count + 8).bigEndian
    withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
    output.append(payload)
    return output
}

let sizes = [("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128),
             ("ic08", 256), ("ic09", 512), ("ic10", 1024)]
var elements = Data()
for (type, pixels) in sizes { elements.append(chunk(type, try draw(size: pixels))) }
try chunk("icns", elements).write(to: target, options: .atomic)
guard let source = CGImageSourceCreateWithURL(target as CFURL, nil),
      CGImageSourceGetCount(source) >= 4 else { throw CocoaError(.fileReadCorruptFile) }
