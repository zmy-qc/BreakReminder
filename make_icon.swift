//
//  make_icon.swift
//  生成 App 图标 (蓝底圆角 + "休" 字) 的 iconset, 供 iconutil 转 .icns
//  用法: make_icon <输出目录>
//

import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let fm = FileManager.default
if !fm.fileExists(atPath: outDir) { try! fm.createDirectory(atPath: outDir, withIntermediateDirectories: true) }

func render(_ px: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: px, height: px))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("无绘图上下文") }

    let rect = CGRect(x: 0, y: 0, width: px, height: px)
    let radius = px * 0.2237
    let clip = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    ctx.saveGState()
    clip.addClip()
    let colors = [NSColor(calibratedRed: 0.22, green: 0.55, blue: 0.98, alpha: 1).cgColor,
                  NSColor(calibratedRed: 0.07, green: 0.30, blue: 0.80, alpha: 1).cgColor]
    if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                             colors: colors as CFArray, locations: [0, 1]) {
        ctx.drawLinearGradient(grad,
                               start: CGPoint(x: px / 2, y: px),
                               end: CGPoint(x: px / 2, y: 0),
                               options: [])
    }
    ctx.restoreGState()

    let para = NSMutableParagraphStyle()
    para.alignment = .center
    let str = NSAttributedString(string: "休", attributes: [
        .font: NSFont.systemFont(ofSize: px * 0.5, weight: .bold),
        .foregroundColor: NSColor.white,
        .paragraphStyle: para,
    ])
    let sz = str.size()
    str.draw(with: NSRect(x: 0, y: (px - sz.height) / 2 - px * 0.02, width: px, height: sz.height),
             options: [.usesLineFragmentOrigin])

    image.unlockFocus()
    return image
}

func write(_ image: NSImage, _ name: String) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { fatalError("PNG 生成失败") }
    try! png.write(to: URL(fileURLWithPath: outDir + "/" + name))
}

let entries: [(Int, String)] = [
    (16, "icon_16x16.png"),    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]
for (px, name) in entries { write(render(CGFloat(px)), name) }
print("iconset 已生成: \(outDir)")
