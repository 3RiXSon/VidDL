import SwiftUI
import Photos

struct HomeView: View {
    @EnvironmentObject var manager: DownloadManager
    @AppStorage("allowAdult") var allowAdult = false
    @AppStorage("apiURL") var apiURL = ""
    @AppStorage("apiKey") var apiKey = ""
    @State var link = ""
    @State var info: VideoInfo?
    @State var loading = false
    @State var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Video link") {
                    TextField("Paste a YouTube, Instagram, Vimeo… link", text: $link)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    HStack {
                        Button("Paste") { link = UIPasteboard.general.string ?? "" }
                        Spacer()
                        Button { Task { await fetch() } } label: { loading ? AnyView(ProgressView()) : AnyView(Text("Find video").bold()) }
                            .disabled(link.isEmpty || loading)
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                if let info {
                    Section("Choose quality — \(info.title)") {
                        ForEach(info.formats) { f in
                            Button { manager.add(title: info.title, format: f); self.info = nil; link = "" } label: {
                                HStack { Text(f.label).bold(); Spacer(); Text(f.ext.uppercased()).foregroundStyle(.secondary); Image(systemName: "arrow.down.circle.fill") }
                            }
                        }
                    }
                }
            }
            .navigationTitle("VidDL")
        }
    }

    func fetch() async {
        loading = true; error = nil; info = nil
        do { info = try await Extractor.resolve(link, allowAdult: allowAdult, apiURL: apiURL, apiKey: apiKey) }
        catch { self.error = error.localizedDescription }
        loading = false
    }
}

struct DownloadsView: View {
    @EnvironmentObject var manager: DownloadManager
    @State var shareURL: URL?
    @State var convertItem: DownloadItem?
    @State var toast: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(manager.items) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.title).font(.headline).lineLimit(1)
                        if item.state != .done { ProgressView(value: item.progress) }
                        HStack {
                            Text(item.state.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            switch item.state {
                            case .downloading: Button("Pause") { manager.pause(item.id) }
                            case .paused, .failed, .queued: Button("Resume") { manager.resume(item.id) }
                            case .done:
                                Menu("Actions") {
                                    Button("Share / Send to app") { shareURL = manager.fileURL(item) }
                                    Button("Save to Photos") { saveToPhotos(item) }
                                    Button("Convert format") { convertItem = item }
                                }
                            }
                        }.buttonStyle(.borderless)
                    }
                }
                .onDelete { idx in idx.map { manager.items[$0].id }.forEach(manager.delete) }
            }
            .overlay { if manager.items.isEmpty { Text("No downloads yet").foregroundStyle(.secondary) } }
            .navigationTitle("Library")
            .sheet(item: Binding(get: { shareURL.map(IdentURL.init) }, set: { shareURL = $0?.url })) { ShareSheet(url: $0.url) }
            .sheet(item: $convertItem) { ConvertView(item: $0) }
            .alert(toast ?? "", isPresented: Binding(get: { toast != nil }, set: { if !$0 { toast = nil } })) { Button("OK") {} }
        }
    }

    func saveToPhotos(_ item: DownloadItem) {
        guard let url = manager.fileURL(item) else { return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { DispatchQueue.main.async { toast = "Photos access denied" }; return }
            PHPhotoLibrary.shared().performChanges({ PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url) }) { ok, err in
                DispatchQueue.main.async { toast = ok ? "Saved to Photos" : (err?.localizedDescription ?? "Couldn't save") }
            }
        }
    }
}

struct ConvertView: View {
    let item: DownloadItem
    @EnvironmentObject var manager: DownloadManager
    @Environment(\.dismiss) var dismiss
    @State var target: Converter.Target = .mp4
    @State var progress: Float = 0
    @State var running = false
    @State var result: String?

    var body: some View {
        NavigationStack {
            Form {
                Picker("Convert to", selection: $target) { ForEach(Converter.Target.allCases) { Text($0.rawValue.uppercased()).tag($0) } }
                    .pickerStyle(.segmented)
                if running { ProgressView(value: progress) }
                if let result { Text(result) }
                Button("Convert") { Task { await run() } }.disabled(running)
            }
            .navigationTitle("Convert").toolbar { Button("Done") { dismiss() } }
        }
    }

    func run() async {
        guard let url = manager.fileURL(item) else { return }
        running = true
        do {
            let out = try await Converter.convert(url, to: target) { p in DispatchQueue.main.async { progress = p } }
            result = "Saved as \(out.lastPathComponent) in Files › VidDL › Videos"
        } catch { result = error.localizedDescription }
        running = false
    }
}

struct SettingsView: View {
    @AppStorage("allowAdult") var allowAdult = false
    @AppStorage("apiURL") var apiURL = ""
    @AppStorage("apiKey") var apiKey = ""
    var body: some View {
        NavigationStack {
            Form {
                Section(footer: Text("Off by default. Turn on to allow adult video sites.")) { Toggle("Allow adult content (18+)", isOn: $allowAdult) }
                Section(header: Text("Video finder server"), footer: Text("A cobalt-compatible server lets VidDL read YouTube, Instagram, Vimeo, Dailymotion, TikTok and more. Without it, only direct video links and simple pages work.")) {
                    TextField("https://your-cobalt-server/", text: $apiURL).textInputAutocapitalization(.never).keyboardType(.URL)
                    SecureField("API key (optional)", text: $apiKey)
                }
                Section { Text("Downloads continue when the app is closed or the screen is locked, and resume after network loss or a restart.").font(.footnote) }
            }.navigationTitle("Settings")
        }
    }
}

struct IdentURL: Identifiable { let url: URL; var id: String { url.absoluteString } }
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
