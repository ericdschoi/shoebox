import SwiftUI
import UIKit
import VisionKit
import PhotosUI
import UniformTypeIdentifiers
import QuickLook
import ShoeboxCore

/// The ways a document can enter the app.
enum CaptureSource: String, Identifiable {
    case scanner
    case photos
    case files
    var id: String { rawValue }

    static var scannerAvailable: Bool { VNDocumentCameraViewController.isSupported }
}

/// Presents the scanner, photo picker or file picker and hands back ready-to-file documents.
/// Attached both to the root view and to the expense editor, since a sheet cannot present from beneath itself.
struct DocumentCaptureModifier: ViewModifier {
    @Binding var source: CaptureSource?
    var onCapture: ([DraftDocument]) -> Void

    @State private var photoItems: [PhotosPickerItem] = []

    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: binding(for: .scanner)) {
                DocumentScanner(onFinish: { pages in
                    source = nil
                    if let draft = DocumentBuilder.draft(fromScannedPages: pages) {
                        onCapture([draft])
                    }
                }, onCancel: {
                    source = nil
                })
                .ignoresSafeArea()
            }
            .photosPicker(isPresented: binding(for: .photos), selection: $photoItems, maxSelectionCount: 6, matching: .images)
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                photoItems = []
                Task {
                    var drafts: [DraftDocument] = []
                    for item in items {
                        if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data),
                           let draft = DocumentBuilder.draft(fromImage: image) {
                            drafts.append(draft)
                        }
                    }
                    if !drafts.isEmpty { onCapture(drafts) }
                }
            }
            .fileImporter(isPresented: binding(for: .files), allowedContentTypes: [.pdf, .image], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                let drafts = urls.compactMap(DocumentBuilder.draft(fromFileAt:))
                if !drafts.isEmpty { onCapture(drafts) }
            }
    }

    private func binding(for target: CaptureSource) -> Binding<Bool> {
        Binding(get: { source == target }, set: { if !$0, source == target { source = nil } })
    }
}

extension View {
    func documentCapture(source: Binding<CaptureSource?>, onCapture: @escaping ([DraftDocument]) -> Void) -> some View {
        modifier(DocumentCaptureModifier(source: source, onCapture: onCapture))
    }
}

/// The menu items shared by every "add a document" button.
struct CaptureMenuItems: View {
    var choose: (CaptureSource) -> Void

    var body: some View {
        if CaptureSource.scannerAvailable {
            Button { choose(.scanner) } label: { Label("Scan document", systemImage: "doc.viewfinder") }
        }
        Button { choose(.photos) } label: { Label("Choose photo", systemImage: "photo.on.rectangle") }
        Button { choose(.files) } label: { Label("Choose file", systemImage: "folder") }
    }
}

struct DocumentScanner: UIViewControllerRepresentable {
    var onFinish: ([UIImage]) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: DocumentScanner
        init(_ parent: DocumentScanner) { self.parent = parent }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            let pages = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
            parent.onFinish(pages)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            parent.onCancel()
        }
    }
}

// MARK: - Thumbnails and preview

/// A paper-shaped thumbnail of a stored document.
struct AttachmentThumbnail: View {
    @Environment(AppModel.self) private var model
    var attachment: Attachment
    var width: CGFloat = 104

    @State private var image: UIImage?

    var body: some View {
        PaperThumbnail(image: image, kind: attachment.kind, width: width)
            .task(id: attachment.id) {
                image = await Thumbnailer.thumbnail(for: attachment, store: model.store)
            }
    }
}

struct PaperThumbnail: View {
    var image: UIImage?
    var kind: AttachmentKind
    var width: CGFloat = 104

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: kind.symbol)
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: width, height: width * 1.3)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.hairline, lineWidth: 0.5))
            Label(kind.label, systemImage: kind.symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(kind.longLabel)
    }
}

/// Wraps the system share sheet.
struct ShareSheet: UIViewControllerRepresentable {
    var items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct ShareItem: Identifiable {
    let id = UUID()
    var url: URL
}
