import SwiftUI
import AppKit

enum HelpTopic: String, CaseIterable, Identifiable {
    case quickStart, darkFrame, fixing, spots, preview, safety, troubleshooting

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quickStart: "Quick Start"
        case .darkFrame: "Making a Hot-Pixel Map"
        case .fixing: "Fixing Photos"
        case .spots: "Removing Spots"
        case .preview: "Spot Preview"
        case .safety: "What Changes in Your Files"
        case .troubleshooting: "Troubleshooting"
        }
    }

    var symbol: String {
        switch self {
        case .quickStart: "star"
        case .darkFrame: "camera.aperture"
        case .fixing: "wand.and.stars"
        case .spots: "sparkle.magnifyingglass"
        case .preview: "square.grid.3x3"
        case .safety: "checkmark.shield"
        case .troubleshooting: "wrench.and.screwdriver"
        }
    }
}

@MainActor
final class HelpModel: ObservableObject {
    static let shared = HelpModel()
    @Published var topic: HelpTopic? = .quickStart
}

// MARK: - Building blocks

private struct Heading: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.title3.bold()).padding(.top, 10) }
}

private struct Para: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }
    var body: some View { Text(text).fixedSize(horizontal: false, vertical: true) }
}

private struct Bullets: View {
    let items: [LocalizedStringKey]
    let numbered: Bool
    init(_ items: [LocalizedStringKey], numbered: Bool = false) { self.items = items; self.numbered = numbered }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(numbered ? "\(i + 1)." : "•").monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 18, alignment: .trailing)
                    Text(item).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct Callout: View {
    let symbol: String
    let text: LocalizedStringKey
    var tint: Color = .accentColor
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).font(.title3)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.1)))
    }
}

private struct ThresholdTable: View {
    let rows: [(String, String)] = [
        ("10–14", "Very aggressive. Thousands of spots per photo, mostly ordinary noise speckle; can touch fine highlights."),
        ("15–19", "Aggressive. Removes faint specks too; check the Preview for real detail being touched."),
        ("20–30", "Recommended. Removes every clearly visible hot pixel without touching real detail."),
        ("40+", "Conservative. Only the most obvious spots."),
    ]
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            ForEach(rows, id: \.0) { r in
                GridRow {
                    Text(r.0).monospacedDigit().bold()
                    Text(r.1).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }
}

// MARK: - Pages

struct HelpPage: View {
    let topic: HelpTopic

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label(topic.title, systemImage: topic.symbol).font(.largeTitle.bold())
                content
            }
            .padding(28)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }

    @ViewBuilder private var content: some View {
        switch topic {
        case .quickStart:
            Para("PixelFixer removes hot, stuck and dead pixels from Nikon NEF raw files. It repairs the raw sensor data itself, so the result is still a normal NEF that opens in Lightroom, DxO PhotoLab, Capture One, NX Studio or Photos as usual, with all its metadata.")
            Heading("Three steps")
            Bullets([
                "**Make a map** (once, then every few months). Take a long exposure with the lens cap on and drop it on the **Dark frame → map** panel. PixelFixer records your sensor’s hot pixels. See *Making a Hot-Pixel Map*.",
                "**Choose your settings.** Pick the map in the **Map** menu. Leave **Remove spots** on with a threshold around **25** to also catch hot pixels the map missed.",
                "**Fix photos.** Drop NEF files or whole folders on the **Drop NEF files to fix** panel. Repaired copies appear in a **Fixed** folder next to the originals.",
            ], numbered: true)
            Callout(symbol: "lightbulb", text: "Not sure about the threshold? Click **Preview…**, drop one of your photos, and move the slider. You’ll see exactly which spots will be removed before changing any files.")
            Heading("Other ways to fix files")
            Bullets([
                "Drop files or folders onto PixelFixer’s **Dock icon**.",
                "In Finder, right-click NEF files and choose **Open With → PixelFixer**.",
                "Use **Choose Files…** in either panel.",
            ])
            Heading("Acknowledgements")
            Para("Inspired by [Pixel Fixer](https://pixelfixer.org/), Thomas Comerford’s freeware hot-pixel remover for Windows. PixelFixer for Mac is a complete, independent rewrite: no code from Pixel Fixer has been copied or used. The original was only the inspiration. This app isn’t affiliated with or endorsed by Pixel Fixer or its author.")

        case .darkFrame:
            Para("A hot-pixel map is a list of the pixels on your sensor that are always faulty. You make one from a **dark frame**: a photo taken with no light reaching the sensor, where every bright pixel must be a defect.")
            Heading("Taking a dark frame")
            Bullets([
                "Put the **lens cap** on (or the body cap), and close the viewfinder blind or cover the eyepiece on a DSLR.",
                "Use **manual exposure** with a **long shutter speed**, ideally matching your typical long exposures (for example 30 s–2 min).",
                "Match the **ISO** you normally use for those shots. Hot pixels behave differently at different ISOs. A dark frame at ISO 3200 won’t catch every hot pixel that appears at ISO 100.",
                "Turn **Long exposure NR off**. Otherwise the camera hides the hot pixels you’re trying to record.",
                "Shoot **raw (NEF)**. Ideally shoot when the camera is warm, for example right after a night session, because hot pixels get worse with heat.",
            ], numbered: true)
            Heading("Creating the map")
            Para("Drop the dark frame (or several, from different exposure times or ISOs) on the **Dark frame → map** panel and give the map a name, such as “Z6 Oct 2026”. When you drop several frames, their hot pixels are combined into one map. The new map is selected automatically. The summary next to the Map menu shows the camera and how many hot and dead pixels it contains.")
            Heading("Managing maps")
            Bullets([
                "Choose a map, or **None**, in the **Map** menu. The choice is remembered.",
                "Click the folder button to open the maps folder (`~/Library/Application Support/PixelFixer/maps`). Delete or rename maps there.",
                "Make a **new map every few months**. Sensors develop new hot pixels over time.",
                "Maps belong to one camera. If a map is used on files from a different camera model, PixelFixer shows a warning.",
            ])
            Callout(symbol: "info.circle", text: "The map and spot removal complement each other. The map catches defects that are always there, even faint ones. Spot removal catches pixels that only light up under particular conditions, such as a much longer exposure than your dark frame.")

        case .fixing:
            Para("Drop NEF files, or folders containing them, on the **Drop NEF files to fix** panel. PixelFixer processes each file in turn and reports the result in the log at the bottom of the window. Each file takes roughly 10–20 seconds.")
            Heading("What gets fixed")
            Bullets([
                "Every pixel in the selected **map**, replaced with the median of its nearest good neighbours of the same colour.",
                "If **Remove spots** is on, isolated bright spots found in each photo (see *Removing Spots*).",
            ])
            Heading("Where repaired files go")
            Bullets([
                "**“Fixed” folder next to originals** (default): `Shoot/DSC_1234.NEF` → `Shoot/Fixed/DSC_1234.NEF`. Your originals are untouched. Files keep their names and dates.",
                "**Overwrite originals**: replaces the files in place. With **Keep .orig backup** ticked, the untouched file is saved as `DSC_1234.NEF.orig` first.",
            ])
            Callout(symbol: "exclamationmark.triangle", text: "Editing sidecars (`.xmp` files from Lightroom, `.dop` files from DxO) stay next to the originals, not in the Fixed folder. To keep your edits, either overwrite the originals, or copy the sidecar into the Fixed folder with the repaired file. Apps that cache previews may need you to re-import, or to refresh the preview, before the change shows.", tint: .orange)
            Heading("Reading the log")
            Bullets([
                "✅ **fixed N pixels**: the file was repaired and verified.",
                "**N pixels from map, M spots found in photo**: the breakdown for that file.",
                "❌ **ERROR**: the file was skipped and left unchanged. See *Troubleshooting*.",
            ])

        case .spots:
            Para("Some hot pixels only appear in certain conditions, such as very long exposures, a warm sensor or a different ISO, so they aren’t in your map. **Remove spots** looks at each photo and removes pixels that very definitely don’t match their surroundings.")
            Heading("What counts as a spot")
            Bullets([
                "**Single hot pixels:** a pixel far brighter than all of its same-colour neighbours, while the pixels directly above and below it aren’t lit. On many sensors, hot pixels bleed into the pixels either side, which looks like a short white or coloured dash. Those neighbours are removed too.",
                "**Small clusters** (when **Clusters** is ticked): a tight group of up to 6 bright pixels, such as a plus shape or a pair, on an otherwise flat background.",
            ])
            Para("Real detail such as lamps, light trails, highlights and fine texture spreads across several pixels in every direction, so it doesn’t pass these tests.")
            Heading("The threshold")
            Para("The threshold is how far a spot must stand out from its surroundings, measured in multiples of the local noise. **Lower values remove fainter spots; higher values remove only the obvious ones.**")
            ThresholdTable()
            Callout(symbol: "moon.stars", text: "**Star photos:** turn **Clusters** off. A small star on a dark sky can look like a cluster of hot pixels. Single-pixel detection is still safe for stars, because a star lights the pixels above and below it too. Check a frame in the Preview first.", tint: .purple)
            Para("Your threshold, Clusters and Remove spots settings are remembered between sessions.")

        case .preview:
            Para("The Spot Preview lets you tune the threshold on a real photo before changing any files. Open it with **Preview…** next to the threshold slider.")
            Bullets([
                "Drop a NEF onto the preview window, or click **Choose Photo…**. Analysis takes 10–20 seconds.",
                "Move the **Threshold** slider. The count and the tiles update instantly.",
                "Each tile shows a zoomed **before → after** crop around one spot, with its strength. The strength is the value the threshold is compared against.",
                "**Removed** spots are listed **weakest first**. The top of the list shows what’s *just* being removed at the current setting, which is where to look for real detail being touched.",
                "**Kept**: spots just below the threshold. These are what you’d gain by lowering it.",
                "Use **Zoom** to make the tiles bigger.",
                "Click **Re-analyse** after changing the map. Changing the Clusters setting re-analyses automatically.",
            ])
            Callout(symbol: "lightbulb", text: "A good routine: lower the slider until the weakest *removed* tiles look like real detail rather than coloured specks, then move it back up a little.")
            Para("Pixels fixed by the map aren’t shown as tiles. Their count appears next to the spot count. The settings in the preview are the same ones the main window uses, so whatever you choose here applies when you fix files.")

        case .safety:
            Para("PixelFixer is careful with your raw files:")
            Bullets([
                "**Lossless.** Before changing anything, PixelFixer re-compresses the photo’s original raw data and checks that it matches the camera’s file **byte for byte**. If it doesn’t, the file is skipped. So the rewritten file uses exactly Nikon’s own lossless compression.",
                "**Only the repaired pixels change.** Every other pixel is identical. Metadata, embedded previews and the JPEG thumbnail are untouched. The only other change is the stored size of the raw data.",
                "**Verified.** After repair, the new file is decoded again and checked against the intended result before it’s saved.",
                "**Safe saving.** Files are written to a temporary file and then swapped in, so a crash or power cut can’t leave a half-written raw.",
                "**Originals kept** by default (Fixed folder), or backed up as `.orig` if you choose to overwrite.",
            ])
            Heading("Supported files")
            Bullets([
                "Nikon NEF with **lossless compressed** raw (12 or 14-bit), tested on the Nikon Z 6.",
                "Uncompressed NEF.",
                "**Not supported:** lossy compressed and High Efficiency (HE / HE★) NEFs. These are refused with an error and left unchanged. Set your camera to *Lossless compressed* for shots you might want to repair.",
            ])

        case .troubleshooting:
            Heading("“python3 not found”")
            Para("PixelFixer’s engine runs on Python. Install it with Homebrew (`brew install python`), then install the libraries it needs: `python3 -m pip install --break-system-packages numpy scipy rawpy pillow`.")
            Heading("“Only lossless-compressed and uncompressed NEFs are supported”")
            Para("The photo was shot with lossy or High Efficiency compression, which PixelFixer can’t rewrite safely. The file has not been changed.")
            Heading("“Re-encoding … didn’t reproduce the file exactly; refusing to modify it”")
            Para("The file is in a variant PixelFixer doesn’t understand, so it refused to touch it rather than risk damage. The file has not been changed.")
            Heading("I can still see a few spots")
            Bullets([
                "Lower the **threshold** a little, using the **Preview** to check it isn’t touching real detail.",
                "Make sure **Clusters** is on, unless it’s a star photo.",
                "Make a new map from a dark frame that matches the problem photo’s **exposure time and ISO**.",
                "Check you’re viewing the file in the **Fixed** folder, and that your editing app has refreshed its preview.",
            ])
            Heading("Real detail was removed")
            Para("Raise the threshold, or turn **Clusters** off. Your originals are still in place unless you chose to overwrite them, so fix them again with the new settings.")
            Heading("The map shows a warning about a different camera")
            Para("Each sensor has its own hot pixels, so a map is only useful for the camera body it was made with. Make a map for each body you own.")
        }
    }
}

struct HelpView: View {
    @ObservedObject var help: HelpModel

    var body: some View {
        NavigationSplitView {
            List(HelpTopic.allCases, selection: $help.topic) { t in
                Label(t.title, systemImage: t.symbol).tag(t)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            HelpPage(topic: help.topic ?? .quickStart)
        }
        .frame(minWidth: 820, minHeight: 560)
    }
}

enum HelpWindow {
    @MainActor private static var window: NSWindow?

    @MainActor static func show(_ topic: HelpTopic? = nil) {
        if let topic { HelpModel.shared.topic = topic }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "PixelFixer Help"
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: HelpView(help: HelpModel.shared))
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
    }
}
