import SwiftUI
import UIKit
import PDFKit
import Vision
import ShoeboxCore

/// A document that has been captured but not yet filed against a saved expense.
struct DraftDocument: Identifiable, Equatable {
    let id = UUID()
    var data: Data
    var fileExtension: String
    var originalName: String
    var kind: AttachmentKind
    var thumbnail: UIImage?

    static func == (lhs: DraftDocument, rhs: DraftDocument) -> Bool {
        lhs.id == rhs.id && lhs.kind == rhs.kind
    }
}

enum DocumentBuilder {
    static let maxPixel: CGFloat = 2400
    static let jpegQuality: CGFloat = 0.62

    /// Scales an image down to a size that keeps small print readable without storing a 12 MB photo,
    /// and re-encodes it as JPEG. Re-encoding also drops location and camera metadata.
    static func normalizedJPEG(from image: UIImage) -> Data? {
        let longest = max(image.size.width, image.size.height) * image.scale
        let factor = min(1, maxPixel / max(longest, 1))
        let target = CGSize(width: max(1, (image.size.width * image.scale * factor).rounded()),
                            height: max(1, (image.size.height * image.scale * factor).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: target))
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return rendered.jpegData(compressionQuality: jpegQuality)
    }

    /// Combines scanned pages into one PDF. Pages are embedded as JPEG so the file stays small.
    static func pdf(from pages: [UIImage]) -> Data? {
        let document = PDFDocument()
        for page in pages {
            guard let jpeg = normalizedJPEG(from: page), let image = UIImage(data: jpeg),
                  let pdfPage = PDFPage(image: image, options: [.compressionQuality: jpegQuality]) else { continue }
            document.insert(pdfPage, at: document.pageCount)
        }
        guard document.pageCount > 0 else { return nil }
        return document.dataRepresentation()
    }

    static func draft(fromScannedPages pages: [UIImage]) -> DraftDocument? {
        guard let data = pdf(from: pages) else { return nil }
        return DraftDocument(data: data, fileExtension: "pdf", originalName: "Scan.pdf", kind: .receipt,
                             thumbnail: pages.first.flatMap { Thumbnailer.downscale($0, to: 240) })
    }

    static func draft(fromImage image: UIImage, name: String = "Photo.jpg") -> DraftDocument? {
        guard let data = normalizedJPEG(from: image) else { return nil }
        return DraftDocument(data: data, fileExtension: "jpg", originalName: name, kind: .receipt,
                             thumbnail: Thumbnailer.downscale(image, to: 240))
    }

    /// Reads a file handed to the app (from the Files picker or another app's share sheet).
    static func draft(fromFileAt url: URL) -> DraftDocument? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var data: Data?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
            data = try? Data(contentsOf: readable)
        }
        guard let data, !data.isEmpty else { return nil }
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent
        if ext == "pdf" || data.prefix(5) == Data("%PDF-".utf8) {
            return DraftDocument(data: data, fileExtension: "pdf", originalName: name, kind: .receipt,
                                 thumbnail: Thumbnailer.thumbnail(forPDF: data, side: 240))
        }
        if let image = UIImage(data: data) {
            return draft(fromImage: image, name: name)
        }
        return nil
    }
}

// MARK: - Thumbnails

enum Thumbnailer {
    private static let cache = NSCache<NSString, UIImage>()

    static func downscale(_ image: UIImage, to side: CGFloat) -> UIImage? {
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { return nil }
        let factor = min(1, side / longest)
        let size = CGSize(width: image.size.width * factor, height: image.size.height * factor)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    static func thumbnail(forPDF data: Data, side: CGFloat) -> UIImage? {
        guard let page = PDFDocument(data: data)?.page(at: 0) else { return nil }
        return page.thumbnail(of: CGSize(width: side * 2, height: side * 2), for: .mediaBox)
    }

    /// Loads (and caches) a thumbnail for a document that is already in the archive.
    static func thumbnail(for attachment: Attachment, store: ArchiveStore, side: CGFloat = 240) async -> UIImage? {
        let key = "\(attachment.id.uuidString)-\(Int(side))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let url = store.url(for: attachment)
        let ext = attachment.fileExtension
        let image = await Task.detached(priority: .utility) { () -> UIImage? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            if ext == "pdf" { return thumbnail(forPDF: data, side: side) }
            return UIImage(data: data).flatMap { downscale($0, to: side) }
        }.value
        if let image { cache.setObject(image, forKey: key) }
        return image
    }
}

// MARK: - Text recognition

enum TextRecognizer {
    /// Returns the document's text as lines in reading order. Runs entirely on the device.
    static func lines(in data: Data, fileExtension: String) async -> [String] {
        await Task.detached(priority: .userInitiated) { () -> [String] in
            if fileExtension == "pdf", let document = PDFDocument(data: data) {
                var lines: [String] = []
                let pages = min(document.pageCount, 3)
                for index in 0..<pages {
                    guard let page = document.page(at: index) else { continue }
                    let embedded = (page.string ?? "").components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    if embedded.joined().count > 24 {
                        // A real text PDF (most EOBs): no need to run recognition.
                        lines.append(contentsOf: embedded)
                    } else {
                        let image = page.thumbnail(of: CGSize(width: 2000, height: 2000), for: .mediaBox)
                        lines.append(contentsOf: recognize(image))
                    }
                }
                return lines
            }
            guard let image = UIImage(data: data) else { return [] }
            return recognize(image)
        }.value
    }

    private static func recognize(_ image: UIImage) -> [String] {
        guard let cgImage = image.cgImage else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: cgOrientation(image.imageOrientation), options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        let fragments = (request.results ?? []).compactMap { observation -> TextFragment? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            // Vision's origin is bottom-left; flip so y grows downward like reading order.
            return TextFragment(text: candidate.string, x: Double(box.minX), y: Double(1 - box.maxY), height: Double(box.height))
        }
        return LineAssembler.lines(from: fragments)
    }

    private static func cgOrientation(_ orientation: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}
