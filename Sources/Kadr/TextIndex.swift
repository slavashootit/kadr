import AppKit

/// Text recognized on saved screenshots, so the history window can search by what a shot says.
/// Kept as a small JSON file; recognition runs one image at a time in the background.
@MainActor
enum TextIndex {
    private static var texts: [String: String] = load()
    private static var queue: [URL] = []
    private static var working = false

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kadr", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("text-index.json")
    }

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return dict
    }

    private static func save() {
        // Forget files that are gone, so the index does not grow forever.
        texts = texts.filter { FileManager.default.fileExists(atPath: $0.key) }
        if let data = try? JSONEncoder().encode(texts) { try? data.write(to: fileURL, options: .atomic) }
    }

    static func matches(_ url: URL, _ query: String) -> Bool {
        let q = query.lowercased()
        if url.lastPathComponent.lowercased().contains(q) { return true }
        return texts[url.path]?.contains(q) ?? false
    }

    static func hasText(_ url: URL) -> Bool { !(texts[url.path] ?? "").isEmpty }

    /// Queues images that are not indexed yet.
    static func index(_ urls: [URL]) {
        let images = urls.filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) && texts[$0.path] == nil }
        queue.append(contentsOf: images.filter { !queue.contains($0) })
        next()
    }

    private static func next() {
        guard !working, !queue.isEmpty else { return }
        working = true
        let url = queue.removeFirst()
        Task { @MainActor in
            var text = ""
            if case let (img, _)? = Thumbs.full(url) {
                // Half-size is plenty for Retina text and several times faster.
                let small = img.width > 2400 ? img.scaled(by: 0.5) ?? img : img
                text = ((try? await OCR.recognize(small)) ?? "").lowercased()
            }
            texts[url.path] = text
            working = false
            if queue.isEmpty {
                save()
                NotificationCenter.default.post(name: .kadrHistoryChanged, object: nil)
            }
            next()
        }
    }
}

/// Moves old captures out of the save folder into "Архів/РРРР-ММ", when the user asked for it.
@MainActor
enum Archiver {
    private static var timer: Timer?

    static func start() {
        run()
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in run() }
        }
    }

    static func run() {
        let days = Prefs.archiveAfterDays
        guard days > 0 else { return }
        let fm = FileManager.default
        let folder = Storage.folder()
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let month = DateFormatter()
        month.dateFormat = "yyyy-MM"
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey, .isRegularFileKey]) else { return }
        var moved = 0
        // Only files Kadr itself named: nothing else in the folder is touched.
        for f in files where f.lastPathComponent.hasPrefix("Kadr ") {
            guard let v = try? f.resourceValues(forKeys: [.creationDateKey, .isRegularFileKey]),
                  v.isRegularFile == true, let created = v.creationDate, created < cutoff else { continue }
            let dir = folder.appendingPathComponent("Архів", isDirectory: true)
                .appendingPathComponent(month.string(from: created), isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(f.lastPathComponent)
            if !fm.fileExists(atPath: dest.path), (try? fm.moveItem(at: f, to: dest)) != nil { moved += 1 }
        }
        if moved > 0 {
            NSLog("Kadr: archived \(moved) capture(s)")
            NotificationCenter.default.post(name: .kadrHistoryChanged, object: nil)
        }
    }
}
