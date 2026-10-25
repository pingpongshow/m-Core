// Draws the placeholder 1024×1024 app icon: radio waves on a blue gradient.
// Usage: swift scripts/make-placeholder-icon.swift <output.png>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!

let gradient = CGGradient(colorsSpace: space, colors: [
    CGColor(srgbRed: 0.15, green: 0.39, blue: 0.92, alpha: 1),
    CGColor(srgbRed: 0.05, green: 0.16, blue: 0.42, alpha: 1),
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])

let center = CGPoint(x: Double(size) / 2, y: Double(size) * 0.42)
ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
ctx.setLineCap(.round)
for (index, radius) in [150.0, 260.0, 370.0].enumerated() {
    ctx.setLineWidth(58 - Double(index) * 6)
    ctx.addArc(center: center, radius: radius, startAngle: .pi * 0.22, endAngle: .pi * 0.78, clockwise: false)
    ctx.strokePath()
}
ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
ctx.fillEllipse(in: CGRect(x: center.x - 62, y: center.y - 62, width: 124, height: 124))

let image = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
precondition(CGImageDestinationFinalize(dest), "failed to write \(output.path)")
