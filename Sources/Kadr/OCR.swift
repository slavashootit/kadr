import AppKit
import Vision

enum OCR {
    /// Recognized text (Ukrainian + English) plus any QR/barcode payloads.
    static func recognize(_ image: CGImage) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let text = VNRecognizeTextRequest()
            text.recognitionLevel = .accurate
            text.usesLanguageCorrection = true
            text.automaticallyDetectsLanguage = true
            if let supported = try? text.supportedRecognitionLanguages() {
                let wanted = ["uk-UA", "en-US", "pl-PL", "de-DE"].filter { supported.contains($0) }
                if !wanted.isEmpty { text.recognitionLanguages = wanted }
            }
            let codes = VNDetectBarcodesRequest()
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([text, codes])

            let observations = text.results ?? []
            // Group into lines top-to-bottom, left-to-right (Vision uses bottom-left normalized coords).
            let sorted = observations.sorted {
                let a = $0.boundingBox, b = $1.boundingBox
                if abs(a.midY - b.midY) > min(a.height, b.height) * 0.5 { return a.midY > b.midY }
                return a.minX < b.minX
            }
            var lines: [String] = []
            var lastY: CGFloat?
            var lastH: CGFloat = 0
            for o in sorted {
                guard let s = o.topCandidates(1).first?.string else { continue }
                let y = o.boundingBox.midY
                if let ly = lastY, abs(ly - y) < min(lastH, o.boundingBox.height) * 0.5, !lines.isEmpty {
                    lines[lines.count - 1] += "  " + s
                } else {
                    lines.append(s)
                }
                lastY = y
                lastH = o.boundingBox.height
            }
            let payloads = (codes.results ?? []).compactMap { $0.payloadStringValue }
            var out = lines.joined(separator: "\n")
            if !payloads.isEmpty { out += (out.isEmpty ? "" : "\n\n") + payloads.joined(separator: "\n") }
            return out
        }.value
    }

    @MainActor
    static func copyText(from image: CGImage) async {
        do {
            let text = try await recognize(image)
            guard !text.isEmpty else { HUD.error("Текст не знайдено"); return }
            Clipboard.copy(text: text)
            HUD.show("Текст скопійовано", symbol: "text.viewfinder", detail: String(text.prefix(160)), seconds: 2.6)
        } catch {
            HUD.error("OCR не вдався: \(error.localizedDescription)")
        }
    }
}
