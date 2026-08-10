import CoreVideo

/// Shared helper for deep-copying a `CVPixelBuffer`.
///
/// ARKit's pixel buffers (captured image, depth map, confidence map) come from a reused buffer
/// pool — holding a bare reference across frames is not safe, since the underlying memory gets
/// overwritten by later frames. Anything that needs to retain a buffer past the current frame
/// callback (RecordedFrameStore, the Step 1 wall texture reference frame) must copy it first.
enum PixelBufferCopy {
    static func copy(_ buffer: CVPixelBuffer) -> CVPixelBuffer? {
        var copy: CVPixelBuffer?
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, attributes as CFDictionary, &copy)
        guard let destination = copy else { return nil }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(destination, [])
        }

        let planeCount = CVPixelBufferGetPlaneCount(buffer)
        if planeCount == 0 {
            if let src = CVPixelBufferGetBaseAddress(buffer), let dst = CVPixelBufferGetBaseAddress(destination) {
                memcpy(dst, src, CVPixelBufferGetDataSize(buffer))
            }
        } else {
            for plane in 0..<planeCount {
                guard let src = CVPixelBufferGetBaseAddressOfPlane(buffer, plane),
                      let dst = CVPixelBufferGetBaseAddressOfPlane(destination, plane) else { continue }
                let planeHeight = CVPixelBufferGetHeightOfPlane(buffer, plane)
                let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                memcpy(dst, src, planeHeight * bytesPerRow)
            }
        }
        return destination
    }
}
