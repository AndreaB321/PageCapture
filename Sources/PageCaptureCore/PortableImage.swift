import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Images in formats that many Markdown viewers and tools cannot show (AVIF, WebP, HEIC, JPEG XL) are saved as PNG.
enum PortableImage {
    private static let convertibleTypes: Set<String> = [
        "public.avif", "public.avis", "public.avci", "public.heic", "public.heics", "public.heif",
        "public.jpeg-xl", "org.webmproject.webp",
    ]

    /// PNG bytes (first frame only) for `data` if it is in a format that should be converted and decodes;
    /// `nil` when it is already portable or cannot be decoded, so the caller keeps the original.
    static func pngData(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?, convertibleTypes.contains(type),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
