// Render Velvet's existing vector mark into tvOS's layered icon format.
// Run from clients/tvos: swift scripts/generate-brand.swift
import AppKit
let root = URL(fileURLWithPath: "VelvetTV/Assets.xcassets")
let fm = FileManager.default
let info: [String: Any] = ["author": "tv.velvet.tvos", "version": 1]
func json(_ directory: URL, _ value: [String: Any]) throws {
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("Contents.json"))
}
func png(_ url: URL, _ width: Int, _ height: Int, foreground: Bool, combined: Bool = false) throws {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    if !foreground || combined {
        let colors = [CGColor(red: 0.13, green: 0.10, blue: 0.22, alpha: 1), CGColor(red: 0.035, green: 0.035, blue: 0.06, alpha: 1)]
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: width, y: 0), options: [])
    }
    if foreground || combined {
        let scale = CGFloat(height) / 105
        ctx.translateBy(x: CGFloat(width)/2 - 54*scale, y: CGFloat(height)/2 + 60*scale)
        ctx.scaleBy(x: scale, y: -scale)
        func polygon(_ points: [CGPoint], _ color: CGColor) {
            ctx.beginPath(); ctx.move(to: points[0]); for p in points.dropFirst() { ctx.addLine(to: p) }; ctx.closePath(); ctx.setFillColor(color); ctx.fillPath()
        }
        polygon([CGPoint(x:36,y:38), CGPoint(x:54,y:76), CGPoint(x:72,y:38), CGPoint(x:80,y:38), CGPoint(x:58,y:82), CGPoint(x:50,y:82), CGPoint(x:28,y:38)], CGColor(red:0.949,green:0.957,blue:0.973,alpha:1))
        polygon([CGPoint(x:54,y:76), CGPoint(x:72,y:38), CGPoint(x:80,y:38), CGPoint(x:58,y:82)], CGColor(red:0.545,green:0.486,blue:0.965,alpha:1))
    }
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}
try json(root, ["info": info])
let brand = root.appendingPathComponent("Brand Assets.brandassets")
var assets: [[String: Any]] = []
for (name, width, height, scales) in [("App Icon",400,240,[1,2]), ("App Store Icon",1280,768,[1])] {
    let stack = brand.appendingPathComponent(name + ".imagestack")
    try json(stack, ["info": info, "layers": [["filename":"Foreground.imagestacklayer"], ["filename":"Background.imagestacklayer"]]])
    for layer in ["Foreground", "Background"] {
        let folder = stack.appendingPathComponent(layer + ".imagestacklayer")
        try json(folder, ["info": info])
        let images = folder.appendingPathComponent("Content.imageset")
        try json(images, ["info": info, "images": scales.map { ["idiom": "tv", "scale": "\($0)x", "filename": "layer\($0)x.png"] }])
        for scale in scales { try png(images.appendingPathComponent("layer\(scale)x.png"), width*scale, height*scale, foreground: layer == "Foreground") }
    }
    assets.append(["idiom": "tv", "size": "\(width)x\(height)", "filename": name + ".imagestack", "role": "primary-app-icon"])
}
for (name, width, height, role) in [("Top Shelf",1920,720,"top-shelf-image"), ("Top Shelf Wide",2320,720,"top-shelf-image-wide")] {
    let folder = brand.appendingPathComponent(name + ".imageset")
    try json(folder, ["info": info, "images": [1,2].map { ["idiom": "tv", "scale": "\($0)x", "filename": "shelf\($0)x.png"] }])
    for scale in [1,2] { try png(folder.appendingPathComponent("shelf\(scale)x.png"), width*scale, height*scale, foreground: false, combined: true) }
    assets.append(["idiom": "tv", "size": "\(width)x\(height)", "filename": name + ".imageset", "role": role])
}
try json(brand, ["info": info, "assets": assets])
