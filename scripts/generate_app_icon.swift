import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let output = CommandLine.arguments[1]
let size = 1024
let colorSpace = CGColorSpaceCreateDeviceRGB()
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.setFillColor(CGColor(red: 0.08, green: 0.25, blue: 0.21, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: size, height: size))
context.setFillColor(CGColor(red: 0.96, green: 0.98, blue: 0.95, alpha: 1)); context.fill(CGRect(x: 260, y: 211, width: 504, height: 602))
context.setFillColor(CGColor(red: 0.31, green: 0.69, blue: 0.56, alpha: 1))
context.beginPath(); context.move(to: CGPoint(x: 260, y: 620)); context.addLine(to: CGPoint(x: 470, y: 420)); context.addLine(to: CGPoint(x: 560, y: 520)); context.addLine(to: CGPoint(x: 764, y: 350)); context.addLine(to: CGPoint(x: 764, y: 813)); context.addLine(to: CGPoint(x: 260, y: 813)); context.closePath(); context.fillPath()
context.setFillColor(CGColor(red: 0.30, green: 0.53, blue: 0.93, alpha: 1)); context.fillEllipse(in: CGRect(x: 340, y: 310, width: 130, height: 130))
let image = context.makeImage()!
let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: output) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil); precondition(CGImageDestinationFinalize(destination))
