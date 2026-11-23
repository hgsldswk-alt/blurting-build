import AVFoundation
import ImageIO
import Photos
import SwiftUI
import UIKit
import Vision

enum PaperOCR {
    static func recognize(_ photos: [Data], language: PaperLanguage) async -> String {
        await Task.detached(priority: .userInitiated) {
            photos.compactMap { data -> String? in
                let request = VNRecognizeTextRequest()
                request.revision = VNRecognizeTextRequestRevision3
                request.recognitionLevel = .accurate
                request.recognitionLanguages = language.recognitionLanguages
                let source = CGImageSourceCreateWithData(data as CFData, nil)
                let info = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [String: Any]
                let raw = info?[kCGImagePropertyOrientation as String] as? UInt32 ?? 1
                let orientation = CGImagePropertyOrientation(rawValue: raw) ?? .up
                let handler = VNImageRequestHandler(data: data, orientation: orientation, options: [:])
                guard (try? handler.perform([request])) != nil else { return nil }
                let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                    .filter { $0.rangeOfCharacter(from: .alphanumerics) != nil }
                return lines.joined(separator: "\n")
            }.filter { !$0.isEmpty }.joined(separator: "\n")
        }.value
    }
}

@MainActor
struct PaperPhotoControls: View {
    @EnvironmentObject private var model: AppModel
    @State private var camera = false
    @State private var album = false
    @State private var waiting = false
    @State private var error: String?
    @State private var captured: Data?
    @State private var selected: [Data] = []
    let remaining: Int
    var primary = false
    let receive: ([Data]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { cameraButton; albumButton }
                VStack(spacing: 8) { cameraButton; albumButton }
            }.disabled(waiting)
            if let error { Text(error).font(.footnote).foregroundStyle(Paper.mark) }
        }
        .fullScreenCover(isPresented: $camera, onDismiss: {
            if let captured {
                self.captured = nil
                receive([captured])
            }
        }) {
            PhotoCamera { data in
                captured = data
                camera = false
            }.ignoresSafeArea()
        }
        .sheet(isPresented: $album, onDismiss: {
            guard !selected.isEmpty else { return }
            let photos = selected
            selected = []
            receive(photos)
        }) {
            LocalAlbum(limit: remaining) { photos in
                selected = photos
                album = false
            }
        }
    }

    private var cameraButton: some View {
        PaperButton(title: L.t(primary ? "paper.capture" : "paper.addPhoto"), id: "paper.capture",
                    symbol: "camera", primary: primary) { openCamera() }
    }

    private var albumButton: some View {
        PaperButton(title: L.t("paper.album"), id: "paper.album", symbol: "photo.on.rectangle") {
            error = nil
            album = true
        }
    }

    private func openCamera() {
        error = nil
        if model.testing {
            guard let encoded = model.environment["BLURTING_PAPER_IMAGE"],
                  let data = Data(base64Encoded: encoded) else {
                error = L.t("paper.cameraUnavailable")
                return
            }
            receive([data])
            return
        }
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            error = L.t("paper.cameraUnavailable")
            return
        }
        waiting = true
        Task {
            let allowed = await AVCaptureDevice.requestAccess(for: .video)
            waiting = false
            if allowed { camera = true } else { error = L.t("paper.cameraDenied") }
        }
    }
}

@MainActor
struct PhotoCamera: UIViewControllerRepresentable {
    let completion: (Data?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let completion: (Data?) -> Void

        init(completion: @escaping (Data?) -> Void) { self.completion = completion }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { completion(nil) }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let original = (info[.imageURL] as? URL).flatMap { try? Data(contentsOf: $0, options: .mappedIfSafe) }
            completion(original ?? (info[.originalImage] as? UIImage)?.jpegData(compressionQuality: 1))
        }
    }
}

@MainActor
private struct LocalAlbum: View {
    @State private var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var assets: PHFetchResult<PHAsset>?
    @State private var selected: [PHAsset] = []
    @State private var loading = false
    @State private var unavailable = false
    let limit: Int
    let receive: ([Data]) -> Void

    var body: some View {
        PaperScroll {
            PageBack()
            PageHeading(title: L.t("paper.album"), subtitle: L.t("paper.albumLimit", limit))
            if status == .denied || status == .restricted {
                Text(L.t("paper.albumDenied")).font(.footnote).foregroundStyle(Paper.muted)
            } else if let assets {
                if assets.count == 0 { Text(L.t("paper.albumEmpty")).foregroundStyle(Paper.muted) }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 3), spacing: 5) {
                    ForEach(0..<assets.count, id: \.self) { index in
                        let asset = assets.object(at: index)
                        let selection = selected.firstIndex(of: asset)
                        Button {
                            if let selection { selected.remove(at: selection) }
                            else if selected.count < limit { selected.append(asset) }
                            unavailable = false
                        } label: {
                            AlbumThumbnail(asset: asset, selection: selection)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L.t("paper.photo", index + 1))
                        .accessibilityAddTraits(selection == nil ? [] : .isSelected)
                        .disabled(loading || (selection == nil && selected.count >= limit))
                    }
                }
            } else {
                ProgressView()
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if loading { ProgressView(L.t("paper.loading")) }
                if unavailable { Text(L.t("paper.albumUnavailable")).font(.footnote).foregroundStyle(Paper.mark) }
                PaperButton(title: L.t("paper.usePhotos"), id: "paper.usePhotos", primary: true) {
                    Task { await loadSelected() }
                }.disabled(loading || selected.isEmpty)
            }.padding(.horizontal, 21).padding(.vertical, 8).background(Paper.background)
        }
        .task {
            if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
            if status == .authorized || status == .limited {
                let options = PHFetchOptions()
                options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                assets = PHAsset.fetchAssets(with: .image, options: options)
            }
        }
    }

    private func loadSelected() async {
        loading = true
        defer { loading = false }
        var photos: [Data] = []
        for asset in selected {
            guard let data = await original(asset) else {
                unavailable = true
                return
            }
            photos.append(data)
        }
        guard !Task.isCancelled else { return }
        receive(photos)
    }

    private func original(_ asset: PHAsset) async -> Data? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.version = .original
            options.isNetworkAccessAllowed = false
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                continuation.resume(returning: data)
            }
        }
    }
}

private struct AlbumThumbnail: View {
    @State private var photo: UIImage?
    @State private var requestID: PHImageRequestID?
    let asset: PHAsset
    let selection: Int?

    var body: some View {
        Color.clear.aspectRatio(1, contentMode: .fit)
            .overlay {
                if let photo {
                    GeometryReader { proxy in
                        Image(uiImage: photo).resizable().scaledToFill()
                            .frame(width: proxy.size.width, height: proxy.size.height).clipped()
                    }
                } else {
                    Color.gray.opacity(0.15)
                    Image(systemName: "photo").foregroundStyle(Paper.muted)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let selection {
                    Text((selection + 1).formatted()).font(.caption.bold()).padding(6)
                        .foregroundStyle(.white).background(Paper.mark, in: Circle()).padding(4)
                }
            }
            .accessibilityHidden(true)
            .onAppear {
                let options = PHImageRequestOptions()
                options.isNetworkAccessAllowed = false
                options.deliveryMode = .opportunistic
                requestID = PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 300, height: 300),
                                                                  contentMode: .aspectFill, options: options) { image, _ in
                    if let image { Task { @MainActor in photo = image } }
                }
            }
            .onDisappear {
                if let requestID { PHImageManager.default().cancelImageRequest(requestID) }
            }
    }
}

@MainActor
struct PaperPhotoPreview: View {
    @EnvironmentObject private var model: AppModel
    @State private var photo: UIImage?
    @State private var loaded = false
    let id: UUID
    let index: Int

    var body: some View {
        Group {
            if let photo {
                Image(uiImage: photo).resizable().scaledToFit()
                    .accessibilityLabel(L.t("paper.photo", index))
                    .accessibilityIdentifier("history.paper.\(index)")
            } else if loaded {
                Text(L.t("paper.photoUnavailable")).font(.footnote).foregroundStyle(Paper.muted)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity)
        .task(id: id) {
            if let data = await model.photo(id) {
                let scaled = await Task.detached(priority: .userInitiated) {
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil as CGImage? }
                    return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 1800
                    ] as CFDictionary)
                }.value
                if let scaled { photo = UIImage(cgImage: scaled) }
            }
            loaded = true
        }
    }
}
