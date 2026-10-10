import AppKit
import PDFKit
import UniformTypeIdentifiers
import Vision

/// The text of a document the person gives the assistant, page by page, read on this Mac: PDFs with PDFKit (scanned
/// pages through on-device OCR), Word, RTF, OpenDocument and HTML through AppKit, images through OCR, and anything
/// that is plain text. The lab service keeps the pages with the conversation; the model reads them with its tools.
enum DocumentReader {
    struct Document {
        var name: String
        var kind: String
        var pages: [String]
        /// Something the model should know about how it was read, e.g. "pages 3-5 read with OCR".
        var note: String
    }

    enum Failure: LocalizedError {
        case tooLarge(String), unreadable(String), noText(String)
        var errorDescription: String? {
            switch self {
            case .tooLarge(let n): return "\(n) is larger than 200 MB."
            case .unreadable(let n): return "Dyno can't read \(n). Try a PDF, Word, RTF, HTML, image or text file."
            case .noText(let n): return "No text could be read from \(n)."
            }
        }
    }

    /// File types the attach panel offers. Anything else is still tried as plain text when dropped.
    static let types: [UTType] = [.pdf, .plainText, .text, .rtf, .rtfd, .html, .image, .json, .xml, .yaml, .commaSeparatedText, .sourceCode,
                                  UTType(filenameExtension: "docx"), UTType(filenameExtension: "doc"), UTType(filenameExtension: "odt"),
                                  UTType(filenameExtension: "md")].compactMap { $0 }

    /// Pages of OCR at most, for scanned PDFs: each page takes about a second.
    static let ocrPageLimit = 300

    static func read(_ url: URL) throws -> Document {
        let name = url.lastPathComponent
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > 200_000_000 { throw Failure.tooLarge(name) }
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        var doc: Document
        if type?.conforms(to: .pdf) == true {
            doc = try pdf(url, name: name)
        } else if type?.conforms(to: .image) == true {
            guard let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw Failure.unreadable(name) }
            doc = Document(name: name, kind: "image", pages: [ocr(image)], note: "Text read from the image with OCR.")
        } else if let rich = richText(url) {
            doc = Document(name: name, kind: url.pathExtension.lowercased(), pages: split(rich), note: "")
        } else if let data = try? Data(contentsOf: url), !data.prefix(8000).contains(0),
                  let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
            doc = Document(name: name, kind: url.pathExtension.lowercased().isEmpty ? "text" : url.pathExtension.lowercased(), pages: split(text), note: "")
        } else {
            throw Failure.unreadable(name)
        }
        if !doc.pages.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { throw Failure.noText(name) }
        return doc
    }

    private static func pdf(_ url: URL, name: String) throws -> Document {
        guard let pdf = PDFDocument(url: url) else { throw Failure.unreadable(name) }
        if pdf.isLocked { throw Failure.unreadable(name + " (password protected)") }
        var pages: [String] = [], scanned: [Int] = []
        for i in 0..<pdf.pageCount {
            guard let page = pdf.page(at: i) else { pages.append(""); continue }
            var text = page.string ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 20, scanned.count < ocrPageLimit, let image = render(page) {
                let read = ocr(image)
                if read.count > text.count { text = read; scanned.append(i + 1) }
            }
            pages.append(text)
        }
        let note = scanned.isEmpty ? "" : "\(scanned.count) scanned page(s) read with OCR, which can misread words."
        return Document(name: name, kind: "pdf", pages: pages, note: note)
    }

    private static func richText(_ url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        let kinds: [String: NSAttributedString.DocumentType] = ["docx": .officeOpenXML, "doc": .docFormat, "odt": .openDocument, "rtf": .rtf,
                                                                 "rtfd": .rtfd, "html": .html, "htm": .html, "webarchive": .webArchive]
        guard let kind = kinds[ext] else { return nil }
        return try? NSAttributedString(url: url, options: [.documentType: kind], documentAttributes: nil).string
    }

    /// Text without pages, in pages of about 4,000 characters at line breaks, so it can be read and quoted by page.
    static func split(_ text: String) -> [String] { LongText.pieces(text, size: 4_000) }

    private static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let scale = min(3, 2400 / max(bounds.width, bounds.height, 1))
        let image = page.thumbnail(of: NSSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private static func ocr(_ image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
