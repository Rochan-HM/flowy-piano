import Foundation
import UIKit
import UniformTypeIdentifiers

/// Turns picked files, photos and document-camera scans into uploads for the recognition server.
enum RecognitionPages {
    /// The server works best with JPEG at 0.8–0.9 quality and the long side at 2500–4000 px.
    static let maxLongSide: CGFloat = 4000
    static let jpegQuality: CGFloat = 0.85

    static func uploads(fromFile url: URL) throws -> [RecognitionUpload] {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw ScoreImportError.unreadable(error.localizedDescription) }

        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        if type?.conforms(to: .pdf) == true || data.starts(with: Array("%PDF".utf8)) {
            return [RecognitionUpload(filename: url.lastPathComponent, mimeType: "application/pdf", data: data)]
        }
        guard let image = UIImage(data: data) else {
            throw ScoreImportError.unsupportedFile(url.pathExtension)
        }
        return [upload(for: image, name: url.deletingPathExtension().lastPathComponent)]
    }

    static func uploads(fromImages images: [UIImage], name: String) -> [RecognitionUpload] {
        images.enumerated().map { index, image in
            upload(for: image, name: images.count == 1 ? name : "\(name)-page\(index + 1)")
        }
    }

    static func upload(for image: UIImage, name: String) -> RecognitionUpload {
        let prepared = resized(image)
        let data = prepared.jpegData(compressionQuality: jpegQuality) ?? Data()
        return RecognitionUpload(filename: "\(name).jpg", mimeType: "image/jpeg", data: data)
    }

    private static func resized(_ image: UIImage) -> UIImage {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let longSide = max(pixelWidth, pixelHeight)
        guard longSide > maxLongSide else { return image }
        let factor = maxLongSide / longSide
        let target = CGSize(width: (pixelWidth * factor).rounded(), height: (pixelHeight * factor).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

/// Generic-password Keychain storage for the server token.
enum Keychain {
    static let service = "com.rochan.indianpiano"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String?, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }
}
