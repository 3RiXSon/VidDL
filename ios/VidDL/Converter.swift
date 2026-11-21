import AVFoundation

/// On-device converter using Apple's media engine.
/// Outputs MP4, MOV, M4V and M4A (audio only). MKV/WebM sources that iOS can't decode are reported clearly.
enum Converter {
    enum Target: String, CaseIterable, Identifiable {
        case mp4, mov, m4v, m4a
        var id: String { rawValue }
        var type: AVFileType { switch self { case .mp4: .mp4; case .mov: .mov; case .m4v: .m4v; case .m4a: .m4a } }
        var preset: String { self == .m4a ? AVAssetExportPresetAppleM4A : AVAssetExportPresetPassthrough }
    }

    static func convert(_ input: URL, to target: Target, progress: @escaping (Float) -> Void) async throws -> URL {
        let asset = AVURLAsset(url: input)
        let out = input.deletingPathExtension().appendingPathExtension("converted.\(target.rawValue)")
        try? FileManager.default.removeItem(at: out)
        var preset = target.preset
        let compatible = await AVAssetExportSession.compatibility(ofExportPreset: preset, with: asset, outputFileType: target.type)
        if !compatible { preset = target == .m4a ? AVAssetExportPresetAppleM4A : AVAssetExportPresetHighestQuality }
        guard let exp = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw NSError(domain: "VidDL", code: 1, userInfo: [NSLocalizedDescriptionKey: "This file's format can't be converted on iOS."])
        }
        exp.outputURL = out; exp.outputFileType = target.type
        let timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in progress(exp.progress) }
        await exp.export()
        timer.invalidate()
        if exp.status != .completed { throw exp.error ?? NSError(domain: "VidDL", code: 2, userInfo: [NSLocalizedDescriptionKey: "Conversion failed."]) }
        return out
    }
}
