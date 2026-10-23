import AppKit

/// Apple's EarPods store photos. They belong to Apple, so instead of shipping them the app downloads
/// them from apple.com on first launch and caches them in Application Support.
@MainActor
final class Photos: ObservableObject {
    static let shared = Photos()

    @Published private(set) var hero: NSImage?
    @Published private(set) var remote: NSImage?

    private struct Source { let name: String, url: URL, crop: CGRect }
    private static let base = "https://store.storeimages.cdn-apple.com/1/as-images.apple.com/is/"
    private static let sources = [
        Source(name: "EarPods", url: URL(string: base + "MTJY3?wid=2400&hei=2400&fmt=png-alpha")!,
               crop: CGRect(x: 568, y: 220, width: 1262, height: 2180)),
        Source(name: "Remote", url: URL(string: base + "MTJY3_AV5?wid=2400&hei=2400&fmt=png-alpha")!,
               crop: CGRect(x: 1080, y: 500, width: 240, height: 1400)),
    ]
    static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("EarPods Control/Photos", isDirectory: true)

    private init() {
        for s in Self.sources { store(s.name, NSImage(contentsOf: file(s.name))) }
        Task { await fetchMissing() }
    }

    private func file(_ name: String) -> URL { Self.folder.appendingPathComponent(name + ".png") }

    private func store(_ name: String, _ image: NSImage?) {
        if name == "EarPods" { hero = image } else { remote = image }
    }

    private func fetchMissing() async {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        for s in Self.sources where (s.name == "EarPods" ? hero : remote) == nil {
            // Offline or Apple moved the image: the UI keeps its placeholder and we retry next launch.
            guard let (data, response) = try? await URLSession.shared.data(from: s.url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let png = Self.crop(data, to: s.crop) else { continue }
            try? png.write(to: file(s.name), options: .atomic)
            store(s.name, NSImage(data: png))
        }
    }

    /// Accepts only a decodable image of the exact size we requested, then crops it.
    nonisolated static func crop(_ data: Data, to rect: CGRect) -> Data? {
        guard let cg = NSBitmapImageRep(data: data)?.cgImage, cg.width == 2400, cg.height == 2400,
              let cropped = cg.cropping(to: rect) else { return nil }
        return NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:])
    }
}
