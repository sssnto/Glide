import Foundation
import CoreText
import CoreGraphics

let fontURL = URL(fileURLWithPath: CommandLine.arguments[1])
let width = Int(CommandLine.arguments[2])!, height = Int(CommandLine.arguments[3])!
let descriptors = CTFontManagerCreateFontDescriptorsFromURL(fontURL as CFURL) as! [CTFontDescriptor]
let font = CTFontCreateWithFontDescriptor(descriptors[0], 30, nil)
var pixels = [UInt8](repeating: 0, count: width * height)
pixels.withUnsafeMutableBytes { bytes in
    let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    context.setFillColor(gray: 0, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: 1, alpha: 1)] as [CFString: Any]
    let text = CFAttributedStringCreate(nil, "PGS 图形字幕" as CFString, attributes as CFDictionary)!
    let line = CTLineCreateWithAttributedString(text)
    context.textPosition = CGPoint(x: (Double(width) - CTLineGetTypographicBounds(line, nil, nil, nil)) / 2, y: 16)
    CTLineDraw(line, context)
}
// Bitmap memory already stores the top row first for the SUP/CGImage raster.
var output = Data()
for row in 0..<height { output.append(contentsOf: pixels[(row * width)..<((row + 1) * width)]) }
FileHandle.standardOutput.write(output)
