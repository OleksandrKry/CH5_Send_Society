import Foundation
import CoreImage
import CoreVideo
import UIKit
import simd

/// IMPLEMENTATION DETAIL OF `SessionStore` — do not call this from outside `Core/Persistence`. See
/// `SessionStore`'s doc comment for why, and add a method there instead of reaching in here.
///
/// Saves/loads an `ARSessionManager.WallTextureReference` to/from disk so a wall scan survives
/// past the live ARSession that captured it — the piece that makes "full 3D mesh export" (the
/// wall-persistence depth Theo chose) possible at all. `ReconstructionEntityBuilder`'s primary
/// wall-rendering path (`makeTexturedMaterial` / the point-cloud wall) only ever reads FROM this
/// struct's fields — never from live `ARMeshAnchor` objects — so reconstructing an equivalent
/// struct from saved files is enough to rebuild the exact same textured/bump-detailed wall a fresh
/// live session would show, without needing to serialize any ARKit mesh geometry at all.
///
/// HIGHEST-RISK FILE IN THIS PASS: CVPixelBuffer creation and pixel-format matching is easy to get
/// subtly wrong, and none of it can be verified without a real device + Xcode. If a reloaded wall
/// looks wrong (blank, garbled colors, wrong scale, or a crash on re-opening a saved session), this
/// file is the first place to check — specifically:
/// - The pixel format constants: `kCVPixelFormatType_32BGRA` for the color image (matches
///   `ARFrame.capturedImage`'s own format, so everything downstream that reads `colorImage`
///   — texture generation, hand-pixel grounding — sees the format it already expects),
///   `kCVPixelFormatType_DepthFloat32` for depth (matches `ARDepthData.depthMap`), and
///   `kCVPixelFormatType_OneComponent8` for confidence (matches `ARConfidenceLevel`'s raw `UInt8`
///   values, one per pixel).
/// - The row-by-row copy loops in `pack*`/`unpack*` below are deliberately NOT a single bulk
///   `memcpy`/`Data` read: `CVPixelBuffer` rows can have alignment padding beyond the actual pixel
///   data (`bytesPerRow` isn't always exactly `width * bytesPerPixel`), and a bulk copy would
///   silently corrupt everything after the first row on any buffer where that's true. Saved files
///   are TIGHTLY packed (no padding); the padding is only ever a live-buffer concern, handled at
///   the pack/unpack boundary.
enum WallScanArchive {
    /// `Codable` written out by hand (keyed container, explicit per-field decode/encode) rather
    /// than relying on Swift's automatic synthesis — synthesis failed to recognize
    /// `simd_float4x4`/`simd_float3x3`'s `Codable` conformance from `CodableSIMD.swift` (a
    /// different file in the same target) with "does not conform to protocol 'Decodable'", even
    /// though those conformances are real and unconditional. Being explicit here only requires
    /// `simd_float4x4.init(from:)`/`simd_float3x3.init(from:)` to work for a single keyed-container
    /// decode call each, which sidesteps whatever synthesis-visibility quirk that was.
    private struct Metadata {
        var cameraTransform: simd_float4x4
        var intrinsics: simd_float3x3
        var imageWidth: Int
        var imageHeight: Int
        var depthWidth: Int?
        var depthHeight: Int?
        var averageDepth: Float?
    }

    private enum MetadataKey: String, CodingKey {
        case cameraTransform, intrinsics, imageWidth, imageHeight, depthWidth, depthHeight, averageDepth
    }

    /// Thin `Codable` wrapper around `Metadata` — writing `Metadata`'s conformance here (via a
    /// keyed container over `MetadataKey`) rather than on `Metadata` itself so the encode/decode
    /// logic is in one obvious place next to the type it serializes.
    private struct MetadataBox: Codable {
        let metadata: Metadata

        init(metadata: Metadata) {
            self.metadata = metadata
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: MetadataKey.self)
            metadata = Metadata(
                cameraTransform: try container.decode(simd_float4x4.self, forKey: .cameraTransform),
                intrinsics: try container.decode(simd_float3x3.self, forKey: .intrinsics),
                imageWidth: try container.decode(Int.self, forKey: .imageWidth),
                imageHeight: try container.decode(Int.self, forKey: .imageHeight),
                depthWidth: try container.decodeIfPresent(Int.self, forKey: .depthWidth),
                depthHeight: try container.decodeIfPresent(Int.self, forKey: .depthHeight),
                averageDepth: try container.decodeIfPresent(Float.self, forKey: .averageDepth)
            )
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: MetadataKey.self)
            try container.encode(metadata.cameraTransform, forKey: .cameraTransform)
            try container.encode(metadata.intrinsics, forKey: .intrinsics)
            try container.encode(metadata.imageWidth, forKey: .imageWidth)
            try container.encode(metadata.imageHeight, forKey: .imageHeight)
            try container.encodeIfPresent(metadata.depthWidth, forKey: .depthWidth)
            try container.encodeIfPresent(metadata.depthHeight, forKey: .depthHeight)
            try container.encodeIfPresent(metadata.averageDepth, forKey: .averageDepth)
        }
    }

    private static let ioSurfaceAttributes: [CFString: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
    ]

    /// Saves `reference` into `baseDirectory/folderName`, creating directories as needed. Returns
    /// `folderName` on success (so the caller can store it on the `RecordingSession`), or nil if
    /// anything failed. A wall-scan save failure shouldn't block saving the rest of the session —
    /// callers should treat nil as "no wall scan for this session," not a fatal error.
    static func save(_ reference: ARSessionManager.WallTextureReference, folderName: String, in baseDirectory: URL) -> String? {
        let folder = baseDirectory.appendingPathComponent(folderName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            DebugLog.reconstruction.error("WallScanArchive.save: couldn't create folder: \(String(describing: error), privacy: .public)")
            return nil
        }

        guard let jpeg = jpegData(from: reference.colorImage) else {
            DebugLog.reconstruction.error("WallScanArchive.save: failed to encode color image")
            return nil
        }
        do {
            try jpeg.write(to: folder.appendingPathComponent("color.jpg"))
        } catch {
            DebugLog.reconstruction.error("WallScanArchive.save: failed to write color.jpg: \(String(describing: error), privacy: .public)")
            return nil
        }

        var metadata = Metadata(
            cameraTransform: reference.cameraTransform,
            intrinsics: reference.intrinsics,
            imageWidth: Int(reference.imageResolution.width),
            imageHeight: Int(reference.imageResolution.height),
            depthWidth: nil,
            depthHeight: nil,
            averageDepth: reference.averageDepth
        )

        // Depth/confidence are best-effort — a wall scan without them still renders (as the
        // coarser flat/textured-only fallback), same as the live-capture struct's own optionality.
        if let depthMap = reference.depthMap, let packed = packFloat32(depthMap) {
            metadata.depthWidth = packed.width
            metadata.depthHeight = packed.height
            try? packed.data.write(to: folder.appendingPathComponent("depth.bin"))
        }
        if let confidenceMap = reference.confidenceMap, let packed = packUInt8(confidenceMap) {
            try? packed.data.write(to: folder.appendingPathComponent("confidence.bin"))
        }

        do {
            let metaData = try JSONEncoder().encode(MetadataBox(metadata: metadata))
            try metaData.write(to: folder.appendingPathComponent("meta.json"))
        } catch {
            DebugLog.reconstruction.error("WallScanArchive.save: failed to write meta.json: \(String(describing: error), privacy: .public)")
            return nil
        }

        return folderName
    }

    /// Reconstructs a `WallTextureReference` from a folder previously written by `save`. Returns
    /// nil if the folder is missing/corrupted or the color image (the one truly required field)
    /// can't be decoded — depth/confidence are optional on load too, matching `save`'s
    /// best-effort handling of them.
    static func load(folderName: String, from baseDirectory: URL) -> ARSessionManager.WallTextureReference? {
        let folder = baseDirectory.appendingPathComponent(folderName, isDirectory: true)
        guard let metaData = try? Data(contentsOf: folder.appendingPathComponent("meta.json")),
              let metadata = (try? JSONDecoder().decode(MetadataBox.self, from: metaData))?.metadata
        else {
            DebugLog.reconstruction.error("WallScanArchive.load: missing/corrupt meta.json for \(folderName, privacy: .public)")
            return nil
        }
        guard let jpeg = try? Data(contentsOf: folder.appendingPathComponent("color.jpg")),
              let colorImage = pixelBuffer(fromJPEGData: jpeg, width: metadata.imageWidth, height: metadata.imageHeight)
        else {
            DebugLog.reconstruction.error("WallScanArchive.load: missing/corrupt color.jpg for \(folderName, privacy: .public)")
            return nil
        }

        var depthMap: CVPixelBuffer?
        var confidenceMap: CVPixelBuffer?
        if let depthWidth = metadata.depthWidth, let depthHeight = metadata.depthHeight {
            if let depthData = try? Data(contentsOf: folder.appendingPathComponent("depth.bin")) {
                depthMap = unpackFloat32(depthData, width: depthWidth, height: depthHeight)
            }
            if let confidenceData = try? Data(contentsOf: folder.appendingPathComponent("confidence.bin")) {
                confidenceMap = unpackUInt8(confidenceData, width: depthWidth, height: depthHeight)
            }
        }

        return ARSessionManager.WallTextureReference(
            colorImage: colorImage,
            cameraTransform: metadata.cameraTransform,
            intrinsics: metadata.intrinsics,
            imageResolution: CGSize(width: metadata.imageWidth, height: metadata.imageHeight),
            depthMap: depthMap,
            confidenceMap: confidenceMap,
            averageDepth: metadata.averageDepth
        )
    }

    /// Deletes a previously-saved wall scan folder — used when a `RecordingSession` is deleted, so
    /// its archived color/depth/confidence files don't linger on disk indefinitely.
    static func delete(folderName: String, from baseDirectory: URL) {
        try? FileManager.default.removeItem(at: baseDirectory.appendingPathComponent(folderName, isDirectory: true))
    }

    // MARK: - Color image <-> JPEG

    /// Same `CIImage(cvPixelBuffer:)` starting point `ReconstructionEntityBuilder.makeTexturedMaterial`
    /// already uses, just encoded to JPEG bytes instead of a `CGImage` for texturing.
    private static func jpegData(from pixelBuffer: CVPixelBuffer) -> Data? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        return CIContext().jpegRepresentation(of: ciImage, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [:])
    }

    /// Decodes JPEG data back into a `kCVPixelFormatType_32BGRA` pixel buffer — see this type's
    /// doc comment for why that specific format matters.
    private static func pixelBuffer(fromJPEGData data: Data, width: Int, height: Int) -> CVPixelBuffer? {
        guard let cgImage = UIImage(data: data)?.cgImage else { return nil }
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, ioSurfaceAttributes as CFDictionary, &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    // MARK: - Depth/confidence <-> tightly-packed raw binary

    private struct PackedGrid {
        let data: Data
        let width: Int
        let height: Int
    }

    /// Reads a `Float32`-per-pixel `CVPixelBuffer` (the format `ARDepthData.depthMap` uses) into a
    /// tightly packed buffer (no row padding), row-by-row — see this type's doc comment for why a
    /// bulk copy would be unsafe here.
    private static func packFloat32(_ pixelBuffer: CVPixelBuffer) -> PackedGrid? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let rowBytes = width * MemoryLayout<Float32>.size

        var packed = Data(count: rowBytes * height)
        packed.withUnsafeMutableBytes { rawBuffer in
            guard let dest = rawBuffer.baseAddress else { return }
            for y in 0..<height {
                let sourceRow = base.advanced(by: y * bytesPerRow)
                let destRow = dest.advanced(by: y * rowBytes)
                destRow.copyMemory(from: sourceRow, byteCount: rowBytes)
            }
        }
        return PackedGrid(data: packed, width: width, height: height)
    }

    /// Same idea as `packFloat32`, but 1 byte per pixel — matches `ARConfidenceLevel`'s raw
    /// `kCVPixelFormatType_OneComponent8` storage.
    private static func packUInt8(_ pixelBuffer: CVPixelBuffer) -> PackedGrid? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        var packed = Data(count: width * height)
        packed.withUnsafeMutableBytes { rawBuffer in
            guard let dest = rawBuffer.baseAddress else { return }
            for y in 0..<height {
                let sourceRow = base.advanced(by: y * bytesPerRow)
                let destRow = dest.advanced(by: y * width)
                destRow.copyMemory(from: sourceRow, byteCount: width)
            }
        }
        return PackedGrid(data: packed, width: width, height: height)
    }

    /// Reverse of `packFloat32` — allocates a fresh `kCVPixelFormatType_DepthFloat32` buffer (whose
    /// OWN `bytesPerRow` may differ from the tightly-packed file layout) and copies row-by-row into
    /// it, rather than assuming the file's packing matches the new buffer's internal layout.
    private static func unpackFloat32(_ data: Data, width: Int, height: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_DepthFloat32, ioSurfaceAttributes as CFDictionary, &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let rowBytes = width * MemoryLayout<Float32>.size

        data.withUnsafeBytes { rawBuffer in
            guard let source = rawBuffer.baseAddress else { return }
            for y in 0..<height {
                let sourceRow = source.advanced(by: y * rowBytes)
                let destRow = base.advanced(by: y * bytesPerRow)
                destRow.copyMemory(from: sourceRow, byteCount: rowBytes)
            }
        }
        return buffer
    }

    private static func unpackUInt8(_ data: Data, width: Int, height: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_OneComponent8, ioSurfaceAttributes as CFDictionary, &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

        data.withUnsafeBytes { rawBuffer in
            guard let source = rawBuffer.baseAddress else { return }
            for y in 0..<height {
                let sourceRow = source.advanced(by: y * width)
                let destRow = base.advanced(by: y * bytesPerRow)
                destRow.copyMemory(from: sourceRow, byteCount: width)
            }
        }
        return buffer
    }
}
