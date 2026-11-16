import UIKit
import CoreImage

/// Separate presentation cache: never reuse or rewrite upstream's bordered icon files.
@MainActor enum LiveBoardIconStore {
    // 图标按 HomeScreen 规格 @3x 生成，单张就是 1MB 级别；覆盖安装和换主题又会让 key 变化、
    // 不停新增条目。之前这两个缓存没有任何上限，内存只涨不落，进后台最先被 jetsam 挑中。
    private static let icons: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()
    private static let backgrounds: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()
    /// 一个 App 的同一套明暗配置只该留一张图；key 变了就把旧条目摘掉，否则它永远占着位置。
    private static var liveKeys: [String: NSString] = [:]
    private static let context = CIContext(options: [.cacheIntermediates: false])
    static func invalidate() { icons.removeAllObjects(); backgrounds.removeAllObjects() }
    /// 更新安装会复用同一个 bundle 路径，只按路径做 key 会命中换包前的旧图标，
    /// 于是「更新完图标没变」。把安装时间也算进 key，新包自然换一张新图。
    private static func cacheKey(_ app: LCAppModel, dark: Bool) -> NSString {
        let stamp = Int(app.appInfo.installationDate?.timeIntervalSince1970 ?? 0)
        let path = app.appInfo.bundlePath()
        let appearance = dark ? ":dark" : ":light"
        let revision = LiveBoardAppCustomization.shared.revision
        return "\(path)\(appearance):\(revision):\(stamp)" as NSString
    }
    private static func retireStale(_ app: LCAppModel, dark: Bool, key: NSString) {
        let identity = "\(app.appInfo.bundlePath())\(dark ? ":dark" : ":light")"
        if let previous = liveKeys[identity], !previous.isEqual(to: key as String) {
            icons.removeObject(forKey: previous)
            backgrounds.removeObject(forKey: previous)
        }
        liveKeys[identity] = key
    }
    static func image(_ app: LCAppModel, dark: Bool) -> UIImage? {
        if let custom = LiveBoardAppCustomization.shared.image(app) { return custom }
        if app.bundleIdentifier.caseInsensitiveCompare("com.EduAlexxis.MusicManager") == .orderedSame,
           let replacement = UIImage(named: "LiveBoardByeTunes", in: .main, compatibleWith: nil) {
            return replacement
        }
        let key = cacheKey(app, dark: dark)
        retireStale(app, dark: dark, key: key)
        if let image = icons.object(forKey: key) { return image }
        if let phone = app.appInfo as? StrataPhoneAppInfo, let image = phone.iconIsDarkIcon(dark) {
            icons.setObject(image, forKey: key, cost: image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0)
            return image
        }
        guard let image = UIImage.generateIcon(forBundleURL: URL(fileURLWithPath: app.appInfo.bundlePath()), style: dark ? .Dark : .Light, hasBorder: false) else { return nil }
        let cleaned = LiveBoardIconEdges.clean(image)
        icons.setObject(cleaned, forKey: key, cost: cleaned.cgImage.map { $0.bytesPerRow * $0.height } ?? 0)
        return cleaned
    }
    static func background(_ app: LCAppModel, dark: Bool) -> UIImage? {
        let key = cacheKey(app, dark: dark)
        if let image = backgrounds.object(forKey: key) { return image }
        guard let source = image(app, dark: dark) else { return nil }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let small = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 160), format: format).image { _ in source.draw(in: CGRect(x: 0, y: 0, width: 160, height: 160)) }
        guard let input = CIImage(image: small), let filter = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputImageKey: input.clampedToExtent(), kCIInputRadiusKey: 18]), let output = filter.outputImage, let cg = context.createCGImage(output, from: input.extent) else { return small }
        let result = UIImage(cgImage: cg)
        backgrounds.setObject(result, forKey: key, cost: cg.bytesPerRow * cg.height)
        return result
    }
}
