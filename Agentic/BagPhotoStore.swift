//
//  BagPhotoStore.swift
//  Agentic
//

import Foundation
import UIKit

/// Bag photographs on disk. Separate from `OwnedBeanStore` so the model layer
/// keeps its Foundation and SwiftData imports and does not grow an opinion
/// about image encoding.
///
/// Two rules the rest of the app depends on. Only the filename is ever stored:
/// the container directory is reassigned on reinstall and on some restores, so
/// a persisted absolute path points at nothing. And the bytes are copied into
/// the container rather than referenced as a `PHAsset`, because an asset
/// reference dies the moment the user tidies their photo library.
nonisolated enum BagPhotoStore {
    /// Enough to re-read a roast date stamp, far less than the camera
    /// produces. OCR has already run by the time anything is saved, so the
    /// full-resolution frame has no reader left.
    static let maxEdge: CGFloat = 1600
    static let compressionQuality: CGFloat = 0.8

    private static let directoryName = "BagPhotos"

    enum PhotoError: Error, LocalizedError {
        case couldNotEncode

        var errorDescription: String? {
            switch self {
            case .couldNotEncode: "That photo could not be saved."
            }
        }
    }

    /// Fixed and known at read time, so a bare filename is still enough to
    /// rebuild the URL.
    private static func directory() throws -> URL {
        let documents = try FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let folder = documents.appending(path: directoryName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Rebuilt from the container every time rather than stored, which is the
    /// whole point of keeping only the filename.
    static func url(for filename: String) -> URL? {
        guard let folder = try? directory() else { return nil }
        return folder.appending(path: filename)
    }

    static func image(named filename: String?) -> UIImage? {
        guard let filename, let url = url(for: filename) else { return nil }
        return UIImage(contentsOfFile: url.path(percentEncoded: false))
    }

    /// `nonisolated async` so the resize runs off the caller's actor. An
    /// eighteen megapixel frame takes long enough to scale that doing it on
    /// the main actor drops frames on the save tap.
    static func save(_ image: UIImage) async throws -> String {
        guard let data = downscaled(image).jpegData(compressionQuality: compressionQuality) else {
            throw PhotoError.couldNotEncode
        }
        let filename = UUID().uuidString + ".jpg"
        try data.write(to: try directory().appending(path: filename), options: .atomic)
        Log.write(.store, "wrote \(filename), \(data.count / 1024)KB")
        return filename
    }

    /// Best effort: a photo left behind is clutter, but failing to delete a
    /// bag because its picture would not unlink is worse.
    static func delete(_ filename: String?) {
        guard let filename, let url = url(for: filename) else { return }
        try? FileManager.default.removeItem(at: url)
        Log.write(.store, "removed \(filename)")
    }

    /// Scales the long edge down to `maxEdge`, preserving aspect ratio and
    /// orientation. An image already smaller is returned untouched rather
    /// than enlarged.
    static func downscaled(_ image: UIImage) -> UIImage {
        let longEdge = max(image.size.width, image.size.height)
        guard longEdge > maxEdge else { return image }

        let scale = maxEdge / longEdge
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1

        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
