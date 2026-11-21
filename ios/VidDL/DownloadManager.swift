import Foundation
import AVFoundation

struct DownloadItem: Identifiable, Codable {
    let id: UUID
    var title: String
    var remote: URL
    var ext: String
    var progress: Double = 0
    var state: State = .queued
    var resumeDataFile: String?
    var localFile: String?
    var taskId: Int?
    enum State: String, Codable { case queued, downloading, paused, failed, done }
}

/// Background URLSession: keeps downloading when the app is closed or the screen locks,
/// and stores resume data so interrupted downloads continue from where they stopped.
final class DownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = DownloadManager()
    @Published var items: [DownloadItem] = []
    var backgroundCompletion: (() -> Void)?
    private var session: URLSession!
    private let store = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private var stateFile: URL { store.appendingPathComponent(".viddl-state.json") }
    var videosDir: URL { let d = store.appendingPathComponent("Videos"); try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true); return d }

    override init() {
        super.init()
        let cfg = URLSessionConfiguration.background(withIdentifier: "com.rixtasy.viddl.bg")
        cfg.sessionSendsLaunchEvents = true
        cfg.isDiscretionary = false
        cfg.waitsForConnectivity = true
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: .main)
        load()
        // Re-attach to tasks the system kept running while the app was closed.
        session.getAllTasks { tasks in
            DispatchQueue.main.async {
                let live = Set(tasks.map(\.taskIdentifier))
                for i in self.items.indices where self.items[i].state == .downloading && !live.contains(self.items[i].taskId ?? -1) {
                    self.items[i].state = .paused
                }
                self.save()
            }
        }
    }

    func add(title: String, format: VideoFormat) {
        if format.ext == "m3u8" { addHLS(title: title, format: format); return }
        var item = DownloadItem(id: UUID(), title: title, remote: format.url, ext: format.ext.isEmpty ? "mp4" : format.ext)
        let task = session.downloadTask(with: format.url)
        task.taskDescription = item.id.uuidString
        item.taskId = task.taskIdentifier; item.state = .downloading
        items.insert(item, at: 0); save(); task.resume()
    }

    func pause(_ id: UUID) {
        session.getAllTasks { tasks in
            guard let t = tasks.first(where: { $0.taskDescription == id.uuidString }) as? URLSessionDownloadTask else { return }
            t.cancel { data in DispatchQueue.main.async { self.storeResume(id, data); self.update(id) { $0.state = .paused } } }
        }
    }

    func resume(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let task: URLSessionDownloadTask
        if let f = item.resumeDataFile, let data = try? Data(contentsOf: store.appendingPathComponent(f)) {
            task = session.downloadTask(withResumeData: data)
        } else { task = session.downloadTask(with: item.remote) }
        task.taskDescription = id.uuidString
        update(id) { $0.state = .downloading; $0.taskId = task.taskIdentifier }
        task.resume()
    }

    func delete(_ id: UUID) {
        pause(id)
        if let f = items.first(where: { $0.id == id })?.localFile { try? FileManager.default.removeItem(at: videosDir.appendingPathComponent(f)) }
        items.removeAll { $0.id == id }; save()
    }

    func fileURL(_ item: DownloadItem) -> URL? { item.localFile.map { videosDir.appendingPathComponent($0) } }

    // MARK: HLS (.m3u8) via AVAssetDownloadURLSession is stream-only; we export to MP4 instead.
    private func addHLS(title: String, format: VideoFormat) {
        let item = DownloadItem(id: UUID(), title: title, remote: format.url, ext: "mp4", state: .downloading)
        items.insert(item, at: 0); save()
        let asset = AVURLAsset(url: format.url)
        guard let exp = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else { update(item.id) { $0.state = .failed }; return }
        let name = safe(title) + "-" + item.id.uuidString.prefix(6) + ".mp4"
        exp.outputURL = videosDir.appendingPathComponent(name); exp.outputFileType = .mp4
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.update(item.id) { $0.progress = Double(exp.progress) } }
        exp.exportAsynchronously {
            DispatchQueue.main.async {
                timer.invalidate()
                self.update(item.id) { if exp.status == .completed { $0.state = .done; $0.progress = 1; $0.localFile = name } else { $0.state = .failed } }
            }
        }
    }

    // MARK: delegate
    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten w: Int64, totalBytesExpectedToWrite t: Int64) {
        guard let id = uuid(downloadTask), t > 0 else { return }
        update(id, persist: false) { $0.progress = Double(w) / Double(t) }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = uuid(downloadTask), let item = items.first(where: { $0.id == id }) else { return }
        let name = safe(item.title) + "-" + id.uuidString.prefix(6) + "." + item.ext
        let dest = videosDir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        do { try FileManager.default.moveItem(at: location, to: dest); update(id) { $0.state = .done; $0.progress = 1; $0.localFile = name } }
        catch { update(id) { $0.state = .failed } }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error as NSError?, let id = uuid(task) else { return }
        if let data = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data { storeResume(id, data) }
        if error.code == NSURLErrorCancelled { return }
        update(id) { $0.state = .paused } // network loss: user (or app relaunch) resumes from saved bytes
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { self.backgroundCompletion?(); self.backgroundCompletion = nil }
    }

    // MARK: helpers
    private func uuid(_ t: URLSessionTask) -> UUID? { t.taskDescription.flatMap(UUID.init) }
    private func storeResume(_ id: UUID, _ data: Data?) {
        guard let data else { return }
        let f = ".resume-\(id.uuidString)"
        try? data.write(to: store.appendingPathComponent(f))
        update(id) { $0.resumeDataFile = f }
    }
    private func update(_ id: UUID, persist: Bool = true, _ f: (inout DownloadItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        f(&items[i]); if persist { save() }
    }
    private func safe(_ s: String) -> String {
        String(s.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }.prefix(60))
    }
    private func save() { try? JSONEncoder().encode(items).write(to: stateFile) }
    private func load() { if let d = try? Data(contentsOf: stateFile) { items = (try? JSONDecoder().decode([DownloadItem].self, from: d)) ?? [] } }
}
