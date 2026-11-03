import Foundation
import CoreImage
import CoreVideo
import UIKit

struct USIFrameSnapshot {
    let sessionID: String
    let metadata: [String: Any]
    let image: CVPixelBuffer
    let depth: CVPixelBuffer?
    let confidence: CVPixelBuffer?
}

struct USIEncodedFrame {
    var metadata: [String: Any]
    let payload: Data
    let previewJPEG: Data
    let depthPreviewPNG: Data?
}

enum USIFrameEncodingError: Error { case invalidBuffer, jpegFailed, frameTooLarge }

/// Invoked on one dedicated encoding queue; retained CVPixelBuffers stay alive until return.
final class USIFrameEncoder {
    private let context = CIContext(options: [.cacheIntermediates: false])

    func encode(_ snapshot: USIFrameSnapshot) throws -> USIEncodedFrame {
        let width = CVPixelBufferGetWidth(snapshot.image), height = CVPixelBufferGetHeight(snapshot.image)
        guard width > 0, height > 0 else { throw USIFrameEncodingError.invalidBuffer }
        let sentWidth = min(640, width)
        let sentHeight = max(1, Int((Double(height) * Double(sentWidth) / Double(width)).rounded()))
        let scaleX = Double(sentWidth) / Double(width), scaleY = Double(sentHeight) / Double(height)
        let image = CIImage(cvPixelBuffer: snapshot.image)
            .transformed(by: CGAffineTransform(scaleX: CGFloat(scaleX), y: CGFloat(scaleY)))
            .cropped(to: CGRect(x: 0, y: 0, width: CGFloat(sentWidth), height: CGFloat(sentHeight)))
        guard let jpeg = context.jpegRepresentation(of: image, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [:]) else {
            throw USIFrameEncodingError.jpegFailed
        }
        var metadata = snapshot.metadata
        metadata["rgb"] = ["encoding": "jpeg", "width": sentWidth, "height": sentHeight, "length": jpeg.count]
        if let original = metadata["intrinsics_row_major"] as? [Double], original.count == 9 {
            var scaled = original
            for index in 0..<3 { scaled[index] *= scaleX; scaled[index + 3] *= scaleY }
            metadata["rgb_intrinsics_row_major"] = scaled
        }
        var payload = jpeg
        metadata["depth"] = NSNull()
        metadata["confidence"] = NSNull()
        if let depth = snapshot.depth,
           CVPixelBufferGetPixelFormatType(depth) == kCVPixelFormatType_DepthFloat32,
           let bytes = try? packRows(depth, elementSize: 4) {
            let dw = CVPixelBufferGetWidth(depth), dh = CVPixelBufferGetHeight(depth)
            metadata["depth"] = ["encoding": "float32_le_m", "width": dw, "height": dh,
                "length": bytes.count, "association": "same_arframe_no_independent_timestamp"]
            payload.append(bytes)
            if let confidence = snapshot.confidence,
               CVPixelBufferGetPixelFormatType(confidence) == kCVPixelFormatType_OneComponent8,
               CVPixelBufferGetWidth(confidence) == dw, CVPixelBufferGetHeight(confidence) == dh,
               let confidenceBytes = try? packRows(confidence, elementSize: 1) {
                metadata["confidence"] = ["encoding": "uint8", "width": dw, "height": dh, "length": confidenceBytes.count]
                payload.append(confidenceBytes)
            }
        }
        guard payload.count <= USIWire.maxPayloadLength else { throw USIFrameEncodingError.frameTooLarge }
        return USIEncodedFrame(metadata: metadata, payload: payload, previewJPEG: jpeg,
                               depthPreviewPNG: snapshot.depth.flatMap { depthPreview($0) })
    }

    /// Visualization only: 0–2 m, near light, invalid black. Recorded bytes stay raw.
    private func depthPreview(_ buffer: CVPixelBuffer) -> Data? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_DepthFloat32,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 0, width <= 8192, height <= 8192, stride >= width * 4 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: Float32.self)
            for x in 0..<width {
                let value = row[x]
                if value.isFinite && value > 0 { pixels[y * width + x] = UInt8(255 * (1 - min(value / 2, 1))) }
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                  bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: image).pngData()
    }

    private func packRows(_ buffer: CVPixelBuffer, elementSize: Int) throws -> Data {
        // Supported iPhones are little-endian. Refuse a different architecture rather than
        // relabeling its native Float32 bytes as the protocol's little-endian encoding.
        guard UInt32(0x01020304).littleEndian == 0x01020304 else { throw USIFrameEncodingError.invalidBuffer }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0, width <= 8192, height <= 8192,
              width * height * elementSize <= USIWire.maxPayloadLength,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            throw USIFrameEncodingError.invalidBuffer
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              CVPixelBufferGetBytesPerRow(buffer) >= width * elementSize else {
            throw USIFrameEncodingError.invalidBuffer
        }
        let rowSize = width * elementSize, stride = CVPixelBufferGetBytesPerRow(buffer)
        var packed = Data(count: rowSize * height)
        packed.withUnsafeMutableBytes { target in
            guard let destination = target.baseAddress else { return }
            for row in 0..<height {
                memcpy(destination.advanced(by: row * rowSize), base.advanced(by: row * stride), rowSize)
            }
        }
        return packed
    }
}
