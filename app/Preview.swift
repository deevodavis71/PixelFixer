import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// One candidate spot from `pixelfixer analyze`, with its before/after zoom crops.
struct Spot: Identifiable {
    let id: Int
    let y: Int, x: Int
    let score: Double
    let before: CGImage?  // nil when the analysis didn't include a crop for this spot
    let after: CGImage?
}

@MainActor
final class PreviewModel: ObservableObject {
    static let shared = PreviewModel()

    @Published var file: URL?
    @Published var spots: [Spot] = []
    @Published var mapPixels = 0
    @Published var analysing = false
    @Published var message = "Drop a photo here to preview which spots will be removed."
    @Published var dropTargeted = false
    @Published var zoom: Double = 4

    func analyse(_ url: URL) {
        guard !analysing else { return }
        file = url
        analysing = true
        spots = []
        message = "Analysing \(url.lastPathComponent)…"
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("PixelFixerPreview/\(UUID().uuidString)")
        var args = ["analyze", url.path, "-o", out.path]
        if let map = AppModel.shared.selectedMap { args += ["-m", map.path] }
        if !AppModel.shared.clustersEnabled { args.append("--no-clusters") }
        Task {
            var errors: [String] = []
            let status = await Engine.run(args) { line, isErr in if isErr { errors.append(line) } }
            analysing = false
            guard status == 0 else {
                message = "Couldn’t analyse: " + (errors.last ?? "unknown error")
                return
            }
            load(out)
            try? FileManager.default.removeItem(at: out)
        }
    }

    func reanalyse() {
        if let file, !analysing { analyse(file) }
    }

    private func load(_ dir: URL) {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("analysis.json")),
              let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = doc["spots"] as? [[String: Any]],
              let before = cgImage(dir.appendingPathComponent("before.png")),
              let after = cgImage(dir.appendingPathComponent("after.png"))
        else { message = "Couldn’t read the analysis results."; return }
        let tile = doc["tile"] as? Int ?? 24, cols = doc["cols"] as? Int ?? 40
        mapPixels = doc["map_pixels_fixed"] as? Int ?? 0
        spots = list.enumerated().map { i, d in
            let t = d["tile"] as? Int ?? -1
            let rect = CGRect(x: (t % cols) * tile, y: (t / cols) * tile, width: tile, height: tile)
            return Spot(id: i, y: d["y"] as? Int ?? 0, x: d["x"] as? Int ?? 0,
                        score: d["score"] as? Double ?? 0,
                        before: t >= 0 ? before.cropping(to: rect) : nil,
                        after: t >= 0 ? after.cropping(to: rect) : nil)
        }
        message = spots.isEmpty ? "No isolated spots found in this photo." : ""
    }

    private func cgImage(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        // Decode now: the temporary files are deleted right after loading.
        let opts = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        return CGImageSourceCreateImageAtIndex(src, 0, opts)
    }
}

struct SpotTile: View {
    let spot: Spot
    let removed: Bool
    let size: CGFloat

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 2) {
                crop(spot.before)
                if removed { crop(spot.after) }
            }
            HStack(spacing: 4) {
                Text(String(format: "%.0f", spot.score)).monospacedDigit().bold()
                Text(removed ? "removed" : "kept").foregroundStyle(removed ? .green : .secondary)
            }
            .font(.caption2)
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(removed ? 0.12 : 0.05)))
        .help("Raw pixel (\(spot.x), \(spot.y)) · strength \(String(format: "%.1f", spot.score))")
    }

    @ViewBuilder private func crop(_ img: CGImage?) -> some View {
        if let img {
            Image(decorative: img, scale: 1).resizable().interpolation(.none)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
    }
}

struct PreviewView: View {
    @ObservedObject var preview: PreviewModel
    @ObservedObject var model: AppModel

    private var threshold: Double { model.spotThreshold }
    private var removed: [Spot] {
        preview.spots.filter { $0.score >= threshold && $0.before != nil }.sorted { $0.score < $1.score }
    }
    private var nearMiss: [Spot] {
        preview.spots.filter { $0.score < threshold && $0.score >= threshold * 0.6 && $0.before != nil }
            .sorted { $0.score > $1.score }.prefix(60).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "photo").foregroundStyle(.secondary)
                Text(preview.file?.lastPathComponent ?? "No photo").font(.headline)
                Spacer()
                Button { HelpWindow.show(.preview) } label: { Image(systemName: "questionmark") }
                    .help("How to use the preview")
                Button("Choose Photo…") { choose() }
                if preview.file != nil {
                    Button("Re-analyse") { if let f = preview.file { preview.analyse(f) } }
                        .help("Run again, e.g. after changing the map")
                }
            }

            SpotControls(model: model)

            HStack {
                if model.spotsEnabled {
                    Text("**\(preview.spots.filter { $0.score >= threshold }.count)** spots will be removed")
                } else {
                    Text("Spot removal is off").foregroundStyle(.secondary)
                }
                if preview.mapPixels > 0 {
                    Text("· plus \(preview.mapPixels) pixels from the map (not shown)").foregroundStyle(.secondary)
                }
                Spacer()
                Text("Zoom").font(.caption).foregroundStyle(.secondary)
                Slider(value: $preview.zoom, in: 2...8).frame(width: 100)
            }
            .font(.callout)

            ZStack {
                if preview.spots.isEmpty {
                    VStack(spacing: 10) {
                        if preview.analysing { ProgressView() }
                        Image(systemName: "viewfinder").font(.system(size: 40, weight: .light))
                        Text(preview.message).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    grid
                    if preview.analysing {
                        ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(preview.dropTargeted ? Color.accentColor.opacity(0.12) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(preview.dropTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
            .onDrop(of: [.fileURL], isTargeted: $preview.dropTargeted) { providers in
                guard let p = providers.first else { return false }
                Task {
                    if let item = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier),
                       let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil),
                       let raw = AppModel.rawFiles(in: [url]).first {
                        await MainActor.run { preview.analyse(raw) }
                    }
                }
                return true
            }
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 560)
    }

    private var grid: some View {
        let size = CGFloat(24 * preview.zoom)
        let cols = [GridItem(.adaptive(minimum: size * 2 + 12), spacing: 8)]
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if model.spotsEnabled {
                    Text("Removed — weakest first, so the borderline ones are at the top (before → after)")
                        .font(.caption).foregroundStyle(.secondary)
                    LazyVGrid(columns: cols, alignment: .leading, spacing: 8) {
                        ForEach(removed) { SpotTile(spot: $0, removed: true, size: size) }
                    }
                }
                if !nearMiss.isEmpty || !model.spotsEnabled {
                    Text(model.spotsEnabled ? "Kept — just below the threshold" : "Detected spots (kept while spot removal is off)")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                    LazyVGrid(columns: cols, alignment: .leading, spacing: 8) {
                        ForEach(model.spotsEnabled ? nearMiss : Array(preview.spots.prefix(120))) {
                            SpotTile(spot: $0, removed: false, size: size)
                        }
                    }
                }
            }
            .padding(10)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "nef") ?? .data]
        if panel.runModal() == .OK, let url = panel.url { preview.analyse(url) }
    }
}

enum PreviewWindow {
    @MainActor private static var window: NSWindow?

    @MainActor static func show(analysing url: URL? = nil) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 680),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "Spot Preview"
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(
                rootView: PreviewView(preview: PreviewModel.shared, model: AppModel.shared))
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        if let url { PreviewModel.shared.analyse(url) }
    }
}
