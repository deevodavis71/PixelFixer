import SwiftUI
import UniformTypeIdentifiers
import AppKit

// MARK: - Engine (runs the bundled Python pixelfixer package)

enum Engine {
    static let pythonCandidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]

    static var python: String? {
        pythonCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs `python3 -m pixelfixer <args>`, streaming each output line to `onLine`.
    static func run(_ args: [String], onLine: @escaping (String, Bool) -> Void) async -> Int32 {
        guard let python else {
            onLine("python3 not found. Install it with Homebrew: brew install python", true)
            return -1
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = ["-m", "pixelfixer"] + args
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        // Keep Python's bytecode cache out of the app bundle, which would break its code signature.
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        env["PYTHONPYCACHEPREFIX"] = cache.appendingPathComponent("PixelFixer/pycache").path
        if let res = Bundle.main.resourcePath { env["PYTHONPATH"] = res + "/engine" }
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        for (pipe, isErr) in [(out, false), (err, true)] {
            let buffer = LineBuffer()
            pipe.fileHandleForReading.readabilityHandler = { h in
                let chunk = h.availableData
                if chunk.isEmpty { h.readabilityHandler = nil; return }
                for line in buffer.add(chunk) {
                    DispatchQueue.main.async { onLine(line, isErr) }
                }
            }
        }
        return await withCheckedContinuation { cont in
            p.terminationHandler = { proc in
                // Let any final output drain before reporting completion.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { cont.resume(returning: proc.terminationStatus) }
            }
            do { try p.run() } catch {
                onLine("Couldn't start python: \(error.localizedDescription)", true)
                cont.resume(returning: -1)
            }
        }
    }
}

/// Splits a byte stream into lines (used from a single pipe's handler queue).
final class LineBuffer: @unchecked Sendable {
    private var data = Data()

    func add(_ chunk: Data) -> [String] {
        data.append(chunk)
        var lines: [String] = []
        while let nl = data.firstIndex(of: 0x0A) {
            let line = String(decoding: data[..<nl], as: UTF8.self)
            data.removeSubrange(...nl)
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }
}

// MARK: - Model

struct LogLine: Identifiable {
    let id = UUID()
    let text: String
    let kind: Kind
    enum Kind { case info, success, error }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var maps: [URL] = []
    @Published var selectedMap: URL?
    @Published var overwrite = false
    @Published var keepBackup = true
    @Published var busy = false
    @Published var targetedZone: String?
    @Published var log: [LogLine] = []
    @Published var progress: (done: Int, total: Int) = (0, 0)
    @Published var spotsEnabled = UserDefaults.standard.object(forKey: "spotsEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(spotsEnabled, forKey: "spotsEnabled") }
    }
    /// Minimum strength (x local noise) for a spot found in a photo to be removed.
    @Published var spotThreshold = min(max(UserDefaults.standard.object(forKey: "spotThreshold") as? Double ?? 25,
                                           AppModel.thresholdRange.lowerBound), AppModel.thresholdRange.upperBound) {
        didSet { UserDefaults.standard.set(spotThreshold, forKey: "spotThreshold") }
    }
    @Published var clustersEnabled = UserDefaults.standard.object(forKey: "clustersEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(clustersEnabled, forKey: "clustersEnabled")
            PreviewModel.shared.reanalyse()  // candidate list depends on this
        }
    }
    static let thresholdRange: ClosedRange<Double> = 10...200

    let mapsDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PixelFixer/maps", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init() {
        installBundledMaps()
        reloadMaps()
    }

    private func installBundledMaps() {
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("maps"),
              let files = try? FileManager.default.contentsOfDirectory(at: bundled, includingPropertiesForKeys: nil)
        else { return }
        for f in files where f.pathExtension == "json" {
            let dst = mapsDir.appendingPathComponent(f.lastPathComponent)
            if !FileManager.default.fileExists(atPath: dst.path) {
                try? FileManager.default.copyItem(at: f, to: dst)
            }
        }
    }

    func reloadMaps(select name: String? = nil) {
        maps = ((try? FileManager.default.contentsOfDirectory(at: mapsDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let saved = name ?? UserDefaults.standard.string(forKey: "selectedMap")
        if saved == "-" { selectedMap = nil; return }
        selectedMap = maps.first { $0.lastPathComponent == saved } ?? selectedMap.flatMap { m in maps.first { $0 == m } } ?? maps.first
    }

    func select(_ url: URL?) {
        selectedMap = url
        UserDefaults.standard.set(url?.lastPathComponent ?? "-", forKey: "selectedMap")
    }

    func append(_ text: String, _ kind: LogLine.Kind = .info) {
        log.append(LogLine(text: text, kind: kind))
    }

    /// Expands dropped files and folders into raw files.
    static func rawFiles(in urls: [URL]) -> [URL] {
        let exts: Set<String> = ["nef", "nrw"]
        var result: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil,
                                                       options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
                while let f = e?.nextObject() as? URL {
                    if exts.contains(f.pathExtension.lowercased()) { result.append(f) }
                }
            } else if exts.contains(url.pathExtension.lowercased()) {
                result.append(url)
            }
        }
        return result.sorted { $0.path < $1.path }
    }

    func fix(_ urls: [URL]) {
        let files = Self.rawFiles(in: urls)
        guard !busy else { return }
        guard !files.isEmpty else { append("No NEF files in what was dropped.", .error); return }
        let map = selectedMap
        guard map != nil || spotsEnabled else {
            append("Choose a hot-pixel map or turn on spot removal first.", .error)
            return
        }
        busy = true
        progress = (0, files.count)
        var how: [String] = []
        if let map { how.append("map “\(map.deletingPathExtension().lastPathComponent)”") }
        if spotsEnabled {
            how.append("spot threshold \(Int(spotThreshold))" + (clustersEnabled ? " incl. clusters" : ""))
        }
        append("Fixing \(files.count) file(s) using \(how.joined(separator: " + "))…")

        // The CLI takes one output folder per run, so process each source folder separately.
        let groups = Dictionary(grouping: files) { $0.deletingLastPathComponent() }
        Task {
            for (folder, group) in groups.sorted(by: { $0.key.path < $1.key.path }) {
                var args = ["fix"]
                if let map { args += ["-m", map.path] }
                if spotsEnabled {
                    args += ["--spots", String(Int(spotThreshold))]
                    if !clustersEnabled { args.append("--no-clusters") }
                }
                if overwrite {
                    args.append("--in-place")
                    if !keepBackup { args.append("--no-backup") }
                } else {
                    args += ["-o", folder.appendingPathComponent("Fixed").path]
                }
                args += group.map(\.path)
                _ = await Engine.run(args) { line, isErr in
                    if line.hasPrefix("Loaded ") { return }
                    let ok = line.contains(": fixed ") || line.contains("nothing to fix")
                    if ok || line.contains(": ERROR") { self.progress.done += 1 }
                    // "DSC_1.NEF: fixed 9 pixels -> /long/path" — the Done message says where files went.
                    let text = (line.components(separatedBy: " -> ").first ?? line)
                        .trimmingCharacters(in: .whitespaces)
                    self.append(text, isErr || line.contains("ERROR") ? .error : ok ? .success : .info)
                }
            }
            busy = false
            append(overwrite ? "Done." : "Done. Repaired files are in a “Fixed” folder next to the originals.")
        }
    }

    func makeMap(from urls: [URL]) {
        let files = Self.rawFiles(in: urls)
        guard !busy, !files.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Name this hot-pixel map"
        alert.informativeText = "For example the camera and date: “Z6 Oct 2026”."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        let date = Date().formatted(.dateTime.month(.abbreviated).year())
        field.stringValue = "Dark frame \(date)"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create Map")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/", with: "-")
        let out = mapsDir.appendingPathComponent((name.isEmpty ? "map" : name) + ".json")

        busy = true
        progress = (0, 0)
        append("Building map from \(files.count) dark frame(s)…")
        Task {
            let status = await Engine.run(["map", "-o", out.path] + files.map(\.path)) { line, isErr in
                if line.hasPrefix("Wrote ") {
                    self.append("Created map “\(out.deletingPathExtension().lastPathComponent)”", .success)
                } else {
                    self.append(line, isErr ? .error : .info)
                }
            }
            busy = false
            if status == 0 {
                reloadMaps(select: out.lastPathComponent)
                select(selectedMap)
            }
        }
    }

    func mapSummary(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        let cam = obj["camera"] as? String ?? "?"
        let hot = obj["hot_count"] as? Int ?? 0
        let dead = obj["dead_count"] as? Int ?? 0
        return "\(cam) · \(hot) hot, \(dead) dead"
    }
}

// MARK: - Views

struct DropZone: View {
    let title: String
    let subtitle: String
    let symbol: String
    let action: ([URL]) -> Void
    @EnvironmentObject var model: AppModel

    private var targeted: Bool { model.targetedZone == title }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 38, weight: .light))
            Text(title).font(.headline)
            Text(subtitle).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Choose Files…") { choose() }.controlSize(.small)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 14).fill(targeted ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 2, dash: [7, 5])))
        .opacity(model.busy ? 0.5 : 1)
        .onDrop(of: [.fileURL], isTargeted: Binding(get: { targeted }, set: { model.targetedZone = $0 ? title : (targeted ? nil : model.targetedZone) })) { providers in
            guard !model.busy else { return false }
            Task {
                var urls: [URL] = []
                for p in providers {
                    if let item = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier),
                       let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                        urls.append(url)
                    }
                }
                await MainActor.run { action(urls) }
            }
            return true
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        if panel.runModal() == .OK { action(panel.urls) }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                DropZone(title: "1. Dark frame → map",
                         subtitle: "Drop a lens-cap-on long exposure to record your sensor’s hot pixels.",
                         symbol: "camera.aperture") { model.makeMap(from: $0) }
                    .frame(width: 230)
                DropZone(title: "2. Drop NEF files to fix",
                         subtitle: "Files or folders. Repaired raws stay as NEF.",
                         symbol: "wand.and.stars") { model.fix($0) }
            }
            .frame(height: 220)

            HStack(alignment: .firstTextBaseline) {
                Picker("Map:", selection: Binding(get: { model.selectedMap }, set: { model.select($0) })) {
                    Text("None").tag(URL?.none)
                    ForEach(model.maps, id: \.self) { url in
                        Text(url.deletingPathExtension().lastPathComponent).tag(URL?.some(url))
                    }
                }
                .frame(maxWidth: 280)
                if let m = model.selectedMap {
                    Text(model.mapSummary(m)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { NSWorkspace.shared.open(model.mapsDir) } label: { Image(systemName: "folder") }
                    .help("Show maps folder")
                Button { HelpWindow.show() } label: { Image(systemName: "questionmark") }
                    .help("PixelFixer Help")
            }

            SpotControls(model: model, showPreviewButton: true)

            HStack {
                Picker("Save to:", selection: $model.overwrite) {
                    Text("“Fixed” folder next to originals").tag(false)
                    Text("Overwrite originals").tag(true)
                }
                .frame(maxWidth: 380)
                if model.overwrite {
                    Toggle("Keep .orig backup", isOn: $model.keepBackup)
                }
                Spacer()
                if model.busy {
                    if model.progress.total > 0 {
                        ProgressView(value: Double(model.progress.done), total: Double(model.progress.total))
                            .frame(width: 120)
                        Text("\(model.progress.done)/\(model.progress.total)").monospacedDigit().font(.caption)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            }

            ScrollViewReader { proxy in
                List(model.log) { line in
                    Label(line.text, systemImage: line.kind == .error ? "xmark.octagon.fill"
                          : line.kind == .success ? "checkmark.circle.fill" : "info.circle")
                        .foregroundStyle(line.kind == .error ? .red : line.kind == .success ? .green : .secondary)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .id(line.id)
                }
                .onChange(of: model.log.count) {
                    if let last = model.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .frame(minHeight: 140)
            .overlay {
                if model.log.isEmpty {
                    Text("Results will appear here").foregroundStyle(.tertiary)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 680, minHeight: 520)
    }
}

/// Toggle + threshold slider for removing spots detected in each photo.
struct SpotControls: View {
    @ObservedObject var model: AppModel
    var showPreviewButton = false

    var body: some View {
        HStack(spacing: 10) {
            Toggle("Remove spots", isOn: $model.spotsEnabled)
                .help("Finds bright pixels in each photo that clearly don’t match their surroundings, e.g. hot pixels missing from the map")
            Text("Threshold").foregroundStyle(model.spotsEnabled ? .primary : .secondary)
            Text("more").font(.caption).foregroundStyle(.secondary)
            Slider(value: Binding(get: { log10(model.spotThreshold) },
                                  set: { model.spotThreshold = (pow(10, $0)).rounded() }),
                   in: log10(AppModel.thresholdRange.lowerBound)...log10(AppModel.thresholdRange.upperBound))
                .frame(minWidth: 140)
            Text("fewer").font(.caption).foregroundStyle(.secondary)
            Text("\(Int(model.spotThreshold))")
                .monospacedDigit().frame(width: 34, alignment: .trailing)
                .help("A spot must stand out from its neighbours by at least this many times the local noise. Lower values remove fainter spots.")
            Toggle("Clusters", isOn: $model.clustersEnabled)
                .disabled(!model.spotsEnabled)
                .help("Also remove tight groups of up to 6 bright pixels on a flat background (plus shapes, pairs). Turn off for star photos — small stars look similar.")
            if showPreviewButton {
                Button("Preview…") { PreviewWindow.show() }
                    .help("Drop a photo to see exactly which spots this threshold removes")
            }
        }
        .disabled(model.busy)
        .opacity(model.spotsEnabled ? 1 : 0.6)
    }
}

// Files dropped on the Dock icon or opened with “Open With → PixelFixer” get fixed directly.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Lets scripts open the preview directly: PIXELFIXER_PREVIEW=/path/photo.NEF
        if let path = ProcessInfo.processInfo.environment["PIXELFIXER_PREVIEW"] {
            Task { @MainActor in PreviewWindow.show(analysing: URL(fileURLWithPath: path)) }
        }
        if let topic = ProcessInfo.processInfo.environment["PIXELFIXER_HELP"] {
            Task { @MainActor in HelpWindow.show(HelpTopic(rawValue: topic)) }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in AppModel.shared.fix(urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct PixelFixerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("PixelFixer", id: "main") {
            ContentView().environmentObject(model)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .help) {
                Button("PixelFixer Help") { HelpWindow.show() }
                    .keyboardShortcut("?", modifiers: .command)
                Divider()
                ForEach(HelpTopic.allCases) { t in
                    Button(t.title) { HelpWindow.show(t) }
                }
            }
        }
    }
}
