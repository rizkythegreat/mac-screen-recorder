import AVKit
import SwiftUI
import UniformTypeIdentifiers

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--selftest") { runSelfTest(); return }
        if let i = args.firstIndex(of: "--render-test"), i + 1 < args.count { runRenderTest(URL(fileURLWithPath: args[i + 1])); return }
        if args.contains("--record-test") { runRecordTest(); return }
        if let i = args.firstIndex(of: "--export"), i + 2 < args.count {
            runExport(URL(fileURLWithPath: args[i + 1]), to: URL(fileURLWithPath: args[i + 2])); return
        }
        StudioApp.main()
    }
}

struct StudioApp: App {
    @StateObject private var recorder = Recorder()
    @State private var openFolder: URL?

    var body: some Scene {
        WindowGroup("Studio") {
            Group {
                if let folder = openFolder {
                    EditorView(folder: folder) { openFolder = nil }.id(folder)
                } else {
                    HomeView(recorder: recorder) { openFolder = $0 }
                }
            }
            .frame(minWidth: 960, minHeight: 680)
            .background(WindowChromeAppearance())
            .tint(StudioTheme.accent)
            .background(StudioTheme.canvas)
            .preferredColorScheme(.dark)
            .toolbarColorScheme(.dark, for: .windowToolbar)
            .toolbarBackground(StudioTheme.surface, for: .windowToolbar)
            .toolbarBackground(.visible, for: .windowToolbar)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands { ProjectHistoryCommands() }

        // Studio's own windows are left out of the recording, so the menu bar is the always-reachable remote.
        MenuBarExtra(isInserted: Binding(get: { recorder.isRecording }, set: { _ in })) {
            RecordingControls(recorder: recorder, open: { openFolder = $0 }, menu: true)
        } label: {
            Image(systemName: recorder.isPaused ? "pause.circle.fill" : "record.circle.fill")
        }
    }
}

/// Pause / resume, stop, restart and cancel. Restart and cancel delete the current take, so they ask first.
struct RecordingControls: View {
    @ObservedObject var recorder: Recorder
    let open: (URL) -> Void
    var menu = false

    var body: some View {
        Button { Task { if let folder = await recorder.stop() { open(folder) } } } label: {
            Label("Stop recording", systemImage: "stop.fill")
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        Button { recorder.isPaused ? recorder.resume() : recorder.pause() } label: {
            Label(recorder.isPaused ? "Resume" : "Pause", systemImage: recorder.isPaused ? "play.fill" : "pause.fill")
        }
        .keyboardShortcut("p", modifiers: [.command, .shift])
        if menu { Divider() }
        Button {
            if confirmDiscard("Restart recording?", "The current take is deleted and a new one starts with the same source.") {
                Task { await recorder.restart() }
            }
        } label: { Label("Restart", systemImage: "arrow.counterclockwise") }
        Button(role: .destructive) {
            if confirmDiscard("Cancel recording?", "The current take is deleted.") { Task { await recorder.cancel() } }
        } label: { Label("Cancel", systemImage: "xmark") }
    }

    private func confirmDiscard(_ title: String, _ detail: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: title.hasPrefix("Restart") ? "Restart" : "Delete take")
        alert.addButton(withTitle: "Keep recording")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }
}

private struct HistoryActions {
    let canUndo: Bool
    let canRedo: Bool
    let undo: () -> Void
    let redo: () -> Void
}

private struct HistoryActionsKey: FocusedValueKey { typealias Value = HistoryActions }
private extension FocusedValues {
    var projectHistory: HistoryActions? {
        get { self[HistoryActionsKey.self] }
        set { self[HistoryActionsKey.self] = newValue }
    }
}

private struct ProjectHistoryCommands: Commands {
    @FocusedValue(\.projectHistory) private var history
    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { history?.undo() }
                .keyboardShortcut("z", modifiers: .command).disabled(history?.canUndo != true)
            Button("Redo") { history?.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(history?.canRedo != true)
        }
    }
}

// MARK: - Home: record + library

struct HomeView: View {
    @ObservedObject var recorder: Recorder
    let open: (URL) -> Void
    @State private var recordings: [URL] = []
    @State private var showCaptureSetup = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(spacing: 12) {
                    Image(systemName: "viewfinder")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(StudioTheme.accent)
                        .frame(width: 44, height: 44)
                        .background(StudioTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 13))
                    Text("Studio").font(.system(size: 22, weight: .semibold))
                    Spacer()
                    Label("Your workspace", systemImage: "internaldrive")
                        .font(.callout).foregroundStyle(.secondary)
                }
                recordingCard
                HStack(alignment: .firstTextBaseline) {
                    Text("Your recordings").font(.system(size: 19, weight: .semibold))
                    Text("\(recordings.count)")
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                    Spacer()
                    Button { NSWorkspace.shared.open(Library.root) } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    .buttonStyle(.borderless)
                }
                if recordings.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "rectangle.stack")
                            .font(.system(size: 30, weight: .light)).foregroundStyle(StudioTheme.accent)
                        Text("A little space for your next idea.").font(.headline)
                        Text("Record your screen to start. Your videos will appear here.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 44)
                    .background(StudioTheme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(StudioTheme.line))
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 18)], spacing: 18) {
                        ForEach(recordings, id: \.self) { url in
                            Button { open(url) } label: {
                                VStack(alignment: .leading, spacing: 0) {
                                    ZStack {
                                        LinearGradient(colors: [StudioTheme.accent.opacity(0.20), StudioTheme.accent.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing)
                                        Image(systemName: "play.rectangle")
                                            .font(.system(size: 34, weight: .ultraLight))
                                            .foregroundStyle(StudioTheme.accent)
                                    }
                                    .frame(height: 116)
                                    HStack {
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(url.lastPathComponent).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                            Text("Open in editor").font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
                                    }.padding(16)
                                }
                                .background(StudioTheme.surface)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(StudioTheme.line))
                                .contentShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(40)
            .frame(maxWidth: 1120)
            .frame(maxWidth: .infinity)
        }
        .onAppear { recordings = Library.recordings() }
        .sheet(isPresented: $showCaptureSetup) { CaptureSetupView(recorder: recorder) }
        .onChange(of: recorder.isBusy) { _, busy in if !busy { recordings = Library.recordings() } }
    }

    private func clock(_ t: Double) -> String { String(format: "%d:%02d", Int(t) / 60, Int(t) % 60) }

    private var recordingCard: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Label(recorder.isPaused ? "PAUSED" : recorder.isRecording ? "RECORDING IN PROGRESS" : "SCREEN RECORDING",
                      systemImage: recorder.isPaused ? "pause.circle.fill" : recorder.isRecording ? "record.circle.fill" : "sparkles")
                    .font(.system(size: 10, weight: .semibold)).tracking(1.8)
                    .foregroundStyle(recorder.isRecording ? Color.red : StudioTheme.accent)
                if recorder.isRecording {
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                        Text(recorder.isPaused ? "Paused at \(clock(recorder.elapsed()))" : "You're rolling · \(clock(recorder.elapsed()))")
                            .font(.system(size: 28, weight: .semibold)).monospacedDigit()
                    }
                } else {
                    Text("Your next recording starts here.").font(.system(size: 28, weight: .semibold))
                }
                Text(recorder.isRecording
                     ? "Capturing \(recorder.sourceName). This window stays out of the shot."
                     : "Capture your screen. Shape the details. Share your work.")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
            }
            HStack(spacing: 18) {
                if recorder.isRecording {
                    HStack(spacing: 8) { RecordingControls(recorder: recorder, open: open) }
                        .disabled(recorder.isBusy)
                } else {
                    Button { showCaptureSetup = true } label: {
                        Label("Record screen", systemImage: "record.circle")
                            .font(.system(size: 13, weight: .semibold)).padding(.horizontal, 8).padding(.vertical, 5)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(recorder.isBusy)
                }
                Toggle("Microphone", isOn: $recorder.includeMic)
                    .toggleStyle(.switch).controlSize(.small)
                    .disabled(recorder.isRecording || recorder.isBusy)
                Spacer()
                Text(recorder.isRecording ? "⇧⌘P pause · ⇧⌘R stop" : "⇧⌘R").font(.caption.monospaced()).foregroundStyle(.tertiary)
            }
            if let error = recorder.error {
                Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [StudioTheme.raised, StudioTheme.surface], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(StudioTheme.line))
    }
}

// MARK: - Editor

struct EditorView: View {
    let folder: URL
    let close: () -> Void

    enum Selection: Equatable { case segment(UUID), zoom(UUID) }

    @State private var recording: Recording?
    @State private var project: Project?
    @State private var history = ProjectHistory()
    @State private var timelineZoom = 1.0
    @ObservedObject private var presets = StylePresetStore.shared
    @State private var selectedPresetID = ""
    @State private var appliedPresetStyle: Style?
    @State private var showSavePreset = false
    @State private var confirmDeletePreset = false
    @State private var presetName = ""
    @State private var presetError: String?
    @FocusState private var presetNameFocused: Bool
    @FocusState private var timelineFocused: Bool
    @State private var player = AVPlayer()
    @State private var now = 0.0  // output time
    @State private var isPlaying = false
    @State private var exportJob: ExportJob?
    @State private var exportTask: Task<Void, Never>?
    @State private var selection: Selection?
    @State private var inspectorTab = InspectorTab.background
    @State private var status: String?
    @State private var pickingFocus = false
    @State private var focusPreviewReady = false
    private struct PreviewRequest: Equatable { var project: Project?; var picking: Bool }
    @State private var buildError: String?
    @State private var exportHeight = 1080.0
    @State private var codec = ExportCodec.h264

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    PlayerView(player: player)
                        .overlay { focusOverlay }
                        .aspectRatio(project?.resolvedCanvas.format.aspectRatio ?? 16 / 9, contentMode: .fit)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.06)))
                        .shadow(color: .black.opacity(0.28), radius: 16, y: 6)
                        .padding(20)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(StudioTheme.canvas)
                        .overlay {
                            if let buildError {
                                Text("Can't play this project: \(buildError)")
                                    .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).padding()
                            }
                        }
                    if let p = project {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                Button(action: togglePlay) {
                                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                        .frame(width: 24, height: 24)
                                }
                                .buttonStyle(StudioToolbarButtonStyle())
                                .keyboardShortcut(.space, modifiers: [])
                                .accessibilityLabel(isPlaying ? "Pause" : "Play")
                                Text(timeString(now)).foregroundStyle(.primary)
                                Text("/ " + timeString(outputDuration(p.segments))).foregroundStyle(.secondary)
                                Spacer()
                                Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                                Slider(value: $timelineZoom, in: 0.5...4)
                                    .controlSize(.mini).frame(width: 72).accessibilityLabel("Timeline zoom")
                                Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
                            }
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            HStack(alignment: .top, spacing: 10) {
                                VStack(spacing: 0) {
                                    Color.clear.frame(height: 22)
                                    Label("Video", systemImage: "film").frame(height: 56)
                                    Color.clear.frame(height: 6)
                                    Label("Zoom", systemImage: "viewfinder").frame(height: 24)
                                }
                                .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                                .frame(width: 54, alignment: .leading)
                                TimelineBar(project: p, folder: folder, duration: recording?.duration ?? 0,
                                            zoom: timelineZoom, now: now, selection: $selection, seek: seek,
                                            beginTrim: { player.pause() }, trim: applyTrim, editZoom: { value in
                                                zoomBinding(value.id)?.wrappedValue = value
                                            }, deleteClip: deleteClip)
                                    .frame(height: 122)
                                    .focusable()
                                    .focusEffectDisabled()
                                    .focused($timelineFocused)
                                    .onDeleteCommand(perform: deleteSelection)
                                    .simultaneousGesture(TapGesture().onEnded { timelineFocused = true })
                            }
                        }
                        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 8)
                        .background(StudioTheme.surface)
                        .overlay(alignment: .top) { StudioTheme.line.frame(height: 1) }
                    }
                }
                Divider()
                if let r = recording {
                    HStack(spacing: 0) {
                        inspectorRail
                        Divider().overlay(StudioTheme.line)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(currentTab.title).font(.system(size: 15, weight: .semibold))
                                .padding(.horizontal, 18).frame(height: 48)
                            ScrollView { inspector(r).frame(maxWidth: .infinity, alignment: .leading) }
                                .scrollIndicators(.hidden)
                        }
                    }
                    .frame(width: 304)
                    .background(StudioTheme.surface)
                }
            }
        }
        .font(.system(size: 12))
        .tint(StudioTheme.accent)
        .background(StudioTheme.canvas)
        .preferredColorScheme(.dark)
        .toolbar { editorToolbar }
        .overlay(alignment: .topTrailing) { statusNotice.padding(12) }
        .task {
            load()
            do { try presets.reload() } catch { presetError = "Couldn't load saved presets: \(error.localizedDescription)" }
        }
        .sheet(isPresented: $showSavePreset) { savePresetSheet }
        .sheet(isPresented: Binding(get: { exportJob != nil }, set: { if !$0 { cancelExport() } })) {
            if let job = exportJob {
                ExportSheet(job: job, cancel: cancelExport, retry: { startExport(to: job.url) }, close: cancelExport)
            }
        }
        .confirmationDialog("Delete this saved preset?", isPresented: $confirmDeletePreset) {
            Button("Delete preset", role: .destructive, action: deletePreset)
        } message: {
            Text("Your recordings will keep their current appearance.")
        }
        .onChange(of: project) { _, p in
            guard let p else { return }
            history.record(p)
            if let appliedPresetStyle, p.style != appliedPresetStyle {
                selectedPresetID = ""
                self.appliedPresetStyle = nil
            }
            do { try writeJSON(p, folder.appendingPathComponent("project.json")) }
            catch { status = "Couldn't save edits: \(error.localizedDescription)" }
            switch selection {
            case .segment(let id) where !p.segments.contains(where: { $0.id == id }): selection = nil
            case .zoom(let id) where !p.zooms.contains(where: { $0.id == id }): selection = nil
            default: break
            }
        }
        .onChange(of: selection) { _, new in
            pickingFocus = false; focusPreviewReady = false
            if new != nil { inspectorTab = .selection }
        }
        .task(id: PreviewRequest(project: project, picking: pickingFocus)) {
            guard project != nil else { return }
            do { try await Task.sleep(nanoseconds: 140_000_000) } catch { return }
            await rebuild()
        }
        .focusedSceneValue(\.projectHistory, HistoryActions(canUndo: history.canUndo, canRedo: history.canRedo,
                                                          undo: undo, redo: redo))
        .onDisappear { player.pause() }
        .onReceive(Timer.publish(every: 1.0 / 30, on: .main, in: .common).autoconnect()) { _ in
            let t = player.currentTime().seconds
            if t.isFinite { now = t }
            // AVPlayer isn't observable: mirror its state so the button flips back to Play at the end.
            let playing = player.timeControlStatus != .paused
            if playing != isPlaying { isPlaying = playing }
        }
    }

    /// Play from the start when the playhead sits at the end, like QuickTime.
    private func togglePlay() {
        if isPlaying { player.pause(); isPlaying = false; return }
        if let p = project, now >= outputDuration(p.segments) - 0.05 { seek(0) }
        player.play()
        isPlaying = true
    }

    // Native toolbar items share the title bar with AppKit's traffic lights.
    // SwiftUI reserves system-control space and manages dragging/fullscreen layout.
    @ToolbarContentBuilder private var editorToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 8) {
                Button { player.pause(); close() } label: {
                    Image(systemName: "sidebar.left").frame(width: 28, height: 28)
                }
                .help("Back to library").accessibilityLabel("Back to library")
                Text(folder.lastPathComponent).font(.system(size: 12, weight: .medium))
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 180, alignment: .leading)
            }
            .buttonStyle(StudioToolbarButtonStyle())
        }
        ToolbarItem(placement: .principal) {
            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    Button(action: undo) { Image(systemName: "arrow.uturn.backward").frame(width: 28, height: 28) }
                        .disabled(!history.canUndo).help("Undo (⌘Z)").accessibilityLabel("Undo")
                    Button(action: redo) { Image(systemName: "arrow.uturn.forward").frame(width: 28, height: 28) }
                        .disabled(!history.canRedo).help("Redo (⇧⌘Z)").accessibilityLabel("Redo")
                }
                Divider().frame(height: 18)
                HStack(spacing: 4) {
                    Button(action: split) { Label("Split", systemImage: "scissors").padding(.horizontal, 8).frame(height: 28) }
                        .keyboardShortcut("b", modifiers: .command).help("Split the selected zoom, or the clip, at the playhead (⌘B)")
                    Button(action: addZoom) { Label("Zoom", systemImage: "plus.magnifyingglass").padding(.horizontal, 8).frame(height: 28) }
                        .keyboardShortcut("z", modifiers: [.command, .option]).help("Add zoom (⌥⌘Z)")
                    Button(role: .destructive, action: deleteSelection) { Image(systemName: "trash").frame(width: 28, height: 28) }
                        .disabled(!canDeleteSelection).help("Delete selection. Keep at least one clip.").accessibilityLabel("Delete selection")
                }
            }
            .font(.system(size: 12, weight: .medium))
            .labelStyle(.titleAndIcon)
            .buttonStyle(StudioToolbarButtonStyle())
        }
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 12) {
                Menu {
                    Picker("Resolution", selection: $exportHeight) {
                        Text("HD · 720p").tag(720.0); Text("Full HD · 1080p").tag(1080.0); Text("4K · 2160p").tag(2160.0)
                    }
                    Picker("Codec", selection: $codec) {
                        ForEach(ExportCodec.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    Text(exportHeight == 720 ? "HD" : exportHeight == 1080 ? "1080p" : "4K")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton).fixedSize().help("Export resolution and codec")
                .accessibilityLabel("Export settings")
                Button(action: export) { Label("Export", systemImage: "square.and.arrow.up").padding(.horizontal, 4) }
                    .buttonStyle(.borderedProminent).controlSize(.regular).keyboardShortcut("e", modifiers: .command)
            }
            .font(.system(size: 12, weight: .medium))
            .labelStyle(.titleAndIcon)
        }
    }

    @ViewBuilder private var statusNotice: some View {
        if let status {
            HStack(spacing: 8) {
                Text(status).font(.caption)
                Button { self.status = nil } label: { Image(systemName: "xmark").font(.caption2) }
                    .buttonStyle(.plain).accessibilityLabel("Dismiss status")
            }.padding(10)
                .background(StudioTheme.raised, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioTheme.line))
        }
    }

    // Non-optional binding into the loaded project (only used once it is loaded).
    private var binding: Binding<Project> {
        Binding(get: { project! }, set: { project = $0 })
    }

    enum InspectorTab: CaseIterable {
        case selection, background, appearance, cursor, webcam, canvas, zooms, presets
        var icon: String {
            switch self {
            case .selection: "cursorarrow.rays"
            case .background: "paintpalette"
            case .appearance: "slider.horizontal.3"
            case .cursor: "cursorarrow.motionlines"
            case .webcam: "video"
            case .canvas: "aspectratio"
            case .zooms: "plus.magnifyingglass"
            case .presets: "square.stack.3d.up"
            }
        }
        var name: String {
            switch self {
            case .selection: "Selection"
            case .background: "Background"
            case .appearance: "Appearance"
            case .cursor: "Cursor"
            case .webcam: "Webcam"
            case .canvas: "Canvas"
            case .zooms: "Automatic zooms"
            case .presets: "Style presets"
            }
        }
    }

    // Selection tab exists only while something on the timeline is selected.
    private var currentTab: (tab: InspectorTab, title: String) {
        let tab = inspectorTab == .selection && selection == nil ? .background : inspectorTab
        return (tab, tab == .selection ? selectionTitle : tab.name)
    }

    private var inspectorRail: some View {
        VStack(spacing: 6) {
            ForEach(InspectorTab.allCases.filter { $0 != .selection || selection != nil }, id: \.self) { tab in
                let active = currentTab.tab == tab
                Button { inspectorTab = tab } label: {
                    Image(systemName: tab.icon).font(.system(size: 14))
                        .frame(width: 32, height: 32)
                        .foregroundStyle(active ? StudioTheme.accent : .secondary)
                        .background(active ? StudioTheme.accent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(active ? StudioTheme.accent.opacity(0.5) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tab.name)
                .accessibilityLabel(tab.name)
                .accessibilityAddTraits(active ? [.isSelected] : [])
            }
            Spacer()
        }
        .padding(.vertical, 10).frame(width: 48)
    }

    @ViewBuilder private func inspector(_ r: Recording) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            switch currentTab.tab {
            case .selection: selectionEditor(r).frame(maxWidth: .infinity, alignment: .leading)
            case .background: backgroundEditor
            case .canvas: canvasEditor(r)
            case .presets: presetEditor
            case .appearance:
                VStack(alignment: .leading, spacing: 12) {
                    styleSlider("Padding", value: binding.style.padding, range: 0...0.25)
                    styleSlider("Corners", value: binding.style.cornerRadius, range: 0...40)
                }
            case .webcam: webcamEditor(r)
            case .cursor:
                VStack(alignment: .leading, spacing: 12) {
                    cursorGrid
                    styleSlider("Cursor size", value: binding.style.cursorScale, range: 0.5...3)
                    styleSlider("Motion blur", value: Binding(get: { project?.style.cursorBlur ?? 0 },
                                                              set: { project?.style.cursorBlur = $0 }), range: 0...1)
                    Divider()
                    Toggle("Smooth cursor", isOn: binding.style.smoothCursor)
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Click effect", selection: Binding(
                            get: { project?.style.resolvedClickEffect ?? .glow },
                            set: { effect in
                                guard var style = project?.style else { return }
                                style.clickEffectStyle = effect
                                style.clickEffect = effect != .off
                                project?.style = style
                            })) {
                            ForEach(ClickEffectStyle.allCases) { effect in
                                Text(effect.title).tag(effect)
                            }
                        }
                        Text((project?.style.resolvedClickEffect ?? .glow).detail)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch).controlSize(.small)
            case .zooms:
                Text("\(project?.zooms.count ?? 0) zooms created from your clicks.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Regenerate zooms") {
                    project?.zooms = Project(recording: r).zooms
                    selection = nil
                }
            }
        }
        .font(.system(size: 12)).controlSize(.small)
        .padding(.horizontal, 18).padding(.bottom, 18)
    }

    private var selectionTitle: String {
        if case .zoom = selection { return "Zoom" }
        return "Video clip"
    }

    private var canvasBinding: Binding<CanvasSettings> {
        Binding(get: { project?.resolvedCanvas ?? CanvasSettings() }, set: { project?.canvas = $0 })
    }

    private func canvasEditor(_ r: Recording) -> some View {
        let settings = project?.resolvedCanvas ?? CanvasSettings()
        let size = settings.format.size(shortEdge: exportHeight)
        let geometry = contentGeometry(source: CGSize(width: r.displayWidth, height: r.displayHeight), canvas: size,
                                       padding: project?.style.padding ?? 0.08, placement: settings.placement)
        return VStack(alignment: .leading, spacing: 12) {
            Picker("Format", selection: canvasBinding.format) {
                ForEach(CanvasFormat.allCases) { format in Text(format.title).tag(format) }
            }.labelsHidden().accessibilityLabel("Video format")
            Text("\(Int(size.width)) × \(Int(size.height)) px at \(exportHeight == 720 ? "HD" : exportHeight == 1080 ? "Full HD" : "4K")")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Picker("Framing", selection: canvasBinding.placement.fit) {
                ForEach(ContentFit.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            Text(settings.placement.fit == .fit ? "Show the whole recording." : "Fill the canvas by cropping the edges.")
                .font(.caption).foregroundStyle(.secondary)
            styleSlider("Horizontal position", value: canvasBinding.placement.horizontal, range: 0...1)
                .disabled(abs(geometry.image.width - geometry.viewport.width) < 0.5)
            styleSlider("Vertical position", value: canvasBinding.placement.vertical, range: 0...1)
                .disabled(abs(geometry.image.height - geometry.viewport.height) < 0.5)
            HStack {
                Text("Position").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button("Center") {
                    var canvas = settings
                    canvas.placement.horizontal = 0.5
                    canvas.placement.vertical = 0.5
                    project?.canvas = canvas
                }
            }
        }
    }

    private var presetEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Style preset", selection: Binding(get: { selectedPresetID }, set: applyPreset)) {
                Text("Choose a preset…").tag("")
                Section("Studio") {
                    ForEach(StylePreset.builtIns) { Text($0.name).tag($0.id) }
                }
                if !presets.custom.isEmpty {
                    Section("Saved") {
                        ForEach(presets.custom) { Text($0.name).tag($0.id) }
                    }
                }
            }.labelsHidden().accessibilityLabel("Style preset")
            HStack {
                Button {
                    presetName = ""; presetError = nil; showSavePreset = true
                } label: { Label("Save preset…", systemImage: "plus") }
                Spacer()
                Menu {
                    Button("Delete selected preset…", role: .destructive) { confirmDeletePreset = true }
                        .disabled(!presets.custom.contains(where: { $0.id == selectedPresetID }))
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).frame(width: 20).accessibilityLabel("Manage presets")
            }
            Text("Reuse your look across recordings.")
                .font(.caption).foregroundStyle(.secondary)
            if let presetError { Text(presetError).font(.caption).foregroundStyle(.red) }
        }
    }

    private var savePresetSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Save your style").font(.title2.weight(.semibold))
            Text("Keep this appearance ready for your next recording.").foregroundStyle(.secondary)
            TextField("Preset name", text: $presetName).textFieldStyle(.roundedBorder)
                .focused($presetNameFocused).onAppear { presetNameFocused = true }
                .onSubmit(savePreset)
            if let presetError { Text(presetError).font(.callout).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { showSavePreset = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save preset", action: savePreset).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || presetName.count > 60)
            }
        }
        .padding(28).frame(width: 420)
    }

    private func applyPreset(_ id: String) {
        guard !id.isEmpty, let preset = presets.all.first(where: { $0.id == id }), var p = project else { return }
        do {
            p.style = try presets.library.appliedStyle(preset, projectFolder: folder)
            appliedPresetStyle = p.style
            selectedPresetID = id
            presetError = nil
            project = p
        } catch {
            selectedPresetID = ""
            presetError = error.localizedDescription
        }
    }

    private func savePreset() {
        guard showSavePreset, let style = project?.style else { return }
        do {
            let preset = try presets.save(name: presetName, style: style, folder: folder)
            selectedPresetID = preset.id
            appliedPresetStyle = style
            presetError = nil
            showSavePreset = false
        } catch { presetError = error.localizedDescription }
    }

    private func deletePreset() {
        guard let preset = presets.custom.first(where: { $0.id == selectedPresetID }) else { return }
        do {
            try presets.delete(preset)
            selectedPresetID = ""; appliedPresetStyle = nil; presetError = nil
        } catch { presetError = error.localizedDescription }
    }

    @ViewBuilder private func webcamEditor(_ recording: Recording) -> some View {
        if recording.webcamOffset != nil {
            let settings = Binding<WebcamSettings>(get: { project?.webcam ?? WebcamSettings() }, set: { project?.webcam = $0 })
            Toggle("Show webcam", isOn: settings.enabled)
            if settings.wrappedValue.enabled {
                Picker("Shape", selection: settings.shape) {
                    ForEach(WebcamSettings.Shape.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                Toggle("Mirror camera", isOn: settings.mirrored)
                styleSlider("Webcam size", value: settings.size, range: 0.12...0.5)
                Text("Position").font(.caption).foregroundStyle(.secondary)
                HStack {
                    ForEach(0..<4) { corner in
                        Button {
                            var value = settings.wrappedValue
                            value.x = corner % 2 == 0 ? 0 : 1
                            value.y = corner < 2 ? 0 : 1
                            settings.wrappedValue = value
                        } label: {
                            Image(systemName: ["arrow.up.left", "arrow.up.right", "arrow.down.left", "arrow.down.right"][corner])
                                .frame(maxWidth: .infinity).frame(height: 24)
                        }
                        .help(["Top left", "Top right", "Bottom left", "Bottom right"][corner])
                        .accessibilityLabel(["Webcam top left", "Webcam top right", "Webcam bottom left", "Webcam bottom right"][corner])
                    }
                }
                styleSlider("Horizontal position", value: settings.x, range: 0...1)
                styleSlider("Vertical position", value: settings.y, range: 0...1)
                Text("The webcam stays in place while the screen zooms. Changes also apply to export.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text("No webcam in this recording").font(.callout.weight(.medium))
            Text("Enable Webcam in New recording to capture your camera alongside the screen.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private static let cursorThumbs: [CursorLook: NSImage] = Dictionary(uniqueKeysWithValues: CursorLook.all.compactMap { look in
        cursorImage(look, height: 48).map { (look, NSImage(cgImage: $0, size: NSSize(width: $0.width / 2, height: $0.height / 2))) }
    })

    private var cursorGrid: some View {
        let current = project?.style.cursorLook
        let color = current ?? CursorLook(shape: .classic, fill: "#9B5CFF", outline: "#FFFFFF")
        return VStack(alignment: .leading, spacing: 10) {
            Button { project?.style.cursorLook = nil } label: {
                HStack {
                    Image(systemName: "cursorarrow")
                    Text("As recorded")
                    Spacer()
                    if current == nil { Image(systemName: "checkmark").foregroundStyle(StudioTheme.accent) }
                }
                .font(.system(size: 11, weight: .medium))
                .padding(9)
                .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .help("Keep the original arrow, hand, and text cursors from the recording")
            .accessibilityAddTraits(current == nil ? [.isSelected] : [])

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 3), spacing: 7) {
                ForEach(CursorLook.Shape.allCases, id: \.self) { shape in
                    let look = CursorLook(shape: shape, fill: color.fill, outline: color.outline)
                    let selected = current?.shape == shape
                    Button { project?.style.cursorLook = look } label: {
                        VStack(spacing: 4) {
                            if let img = Self.cursorThumbs[look] {
                                Image(nsImage: img).resizable().scaledToFit().frame(height: 28)
                            }
                            Text(shape.title).font(.system(size: 10, weight: .medium))
                        }
                        .frame(maxWidth: .infinity).frame(height: 57)
                        .background(.white.opacity(selected ? 0.08 : 0.035), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(selected ? StudioTheme.accent : .white.opacity(0.08), lineWidth: selected ? 2 : 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(shape.title) replaces all recorded cursor shapes")
                    .accessibilityLabel("\(shape.title) cursor")
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }
            if current != nil {
                Text("Color").font(.system(size: 11)).foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    ForEach(CursorLook.palette, id: \.name) { swatch in
                        cursorSwatch(swatch, look: color)
                    }
                }
                Text("Custom styles replace every recorded cursor shape.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func cursorSwatch(_ swatch: (name: String, fill: String, outline: String), look: CursorLook) -> some View {
        let selected = look.fill == swatch.fill
        let tint = ciColor(hex: swatch.fill)
        return Button {
            project?.style.cursorLook = CursorLook(shape: look.shape, fill: swatch.fill, outline: swatch.outline)
        } label: {
            Circle().fill(Color(red: tint.red, green: tint.green, blue: tint.blue))
                .frame(width: 18, height: 18)
                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                .padding(2)
                .overlay(Circle().strokeBorder(selected ? StudioTheme.accent : .clear, lineWidth: 2))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(swatch.name)
        .accessibilityLabel("\(swatch.name) cursor color")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func styleSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).foregroundStyle(.secondary)
                Spacer()
                Text(sliderValue(title, value: value.wrappedValue))
                    .monospacedDigit().foregroundStyle(.secondary)
            }.font(.system(size: 11))
            Slider(value: value, in: range, onEditingChanged: editingChanged).labelsHidden().accessibilityLabel(title)
        }
    }

    private func sliderValue(_ title: String, value: Double) -> String {
        switch title {
        case "Webcam size", "Padding", "Motion blur", "Horizontal position", "Vertical position": return "\(Int((value * 100).rounded()))%"
        case "Cursor size": return String(format: "%.1f×", value)
        case "Corners": return "\(Int(value.rounded())) px"
        default: return String(format: "%.1f", value)
        }
    }

    private static let gradientPresets = [
        ("#3F37C9", "#7B2FF7"), ("#FF5F6D", "#FFC371"), ("#11998E", "#38EF7D"),
        ("#2193B0", "#6DD5ED"), ("#EE9CA7", "#FFDDE1"), ("#232526", "#414345"),
    ]

    @ViewBuilder private var backgroundEditor: some View {
        let style = project?.style ?? Style()
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(Self.gradientPresets, id: \.0) { top, bottom in
                    let selected = style.backgroundImage == nil && style.backgroundTop == top && style.backgroundBottom == bottom
                    Button { setGradient(top: top, bottom: bottom) } label: {
                        Circle()
                        .fill(LinearGradient(colors: [hexColor(.constant(top)).wrappedValue, hexColor(.constant(bottom)).wrappedValue],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 22, height: 22)
                        .overlay(Circle().stroke(Color.primary.opacity(selected ? 0.9 : 0.15), lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Gradient \(top) to \(bottom)")
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }
            HStack {
                ColorPicker("Gradient", selection: gradientColor(\.backgroundTop), supportsOpacity: false)
                ColorPicker("to", selection: gradientColor(\.backgroundBottom), supportsOpacity: false).labelsHidden()
            }
            HStack {
                Button("My wallpaper", action: useWallpaper)
                Button("Image…", action: chooseImage)
            }
            if style.backgroundImage != nil {
                Slider(value: Binding(get: { project?.style.backgroundBlur ?? 0 }, set: { project?.style.backgroundBlur = $0 }),
                       in: 0...40, onEditingChanged: editingChanged) { Text("Blur") }
            }
        }
    }

    private func setGradient(top: String, bottom: String) {
        guard var s = project?.style else { return }
        (s.backgroundTop, s.backgroundBottom, s.backgroundImage) = (top, bottom, nil)
        project?.style = s
    }

    private func gradientColor(_ kp: WritableKeyPath<Style, String>) -> Binding<Color> {
        hexColor(Binding(
            get: { project?.style[keyPath: kp] ?? "#000000" },
            set: { hex in
                guard var s = project?.style else { return }
                s[keyPath: kp] = hex
                s.backgroundImage = nil  // editing a color switches back to the gradient
                project?.style = s
            }))
    }

    private func useWallpaper() {
        guard let screen = NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for: screen) else {
            status = "Couldn't find your wallpaper."
            return
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            status = "Your wallpaper file \(url.lastPathComponent) is missing. Use Image… instead."
            return
        }
        setBackground(url)
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.directoryURL = URL(fileURLWithPath: "/System/Library/Desktop Pictures")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setBackground(url)
    }

    /// Copies the image into the recording folder so the project stays self-contained.
    private func setBackground(_ source: URL) {
        guard CIImage(contentsOf: source) != nil else {
            status = "Can't read \(source.lastPathComponent) as a picture (aerial/dynamic wallpapers aren't image files). Choose a picture instead."
            return
        }
        let name = "background-\(UUID().uuidString.prefix(8)).\(source.pathExtension.isEmpty ? "png" : source.pathExtension)"
        do {
            try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent(name))
            guard var s = project?.style else { return }
            s.backgroundImage = name
            s.backgroundBlur = s.backgroundBlur ?? 0
            project?.style = s
            // Keep prior images: undo snapshots may still reference them.
        } catch {
            status = "Couldn't use that image: \(error.localizedDescription)"
        }
    }

    @ViewBuilder private func selectionEditor(_ r: Recording) -> some View {
        switch selection {
        case .zoom(let id):
            if let z = zoomBinding(id) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Enabled", isOn: z.enabled)
                    Text(z.wrappedValue.focus == nil ? "Focus follows cursor" : "Fixed focus point")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(pickingFocus ? "Cancel focus selection" : "Choose focus in preview") {
                        player.pause()
                        focusPreviewReady = false
                        pickingFocus.toggle()
                    }
                    if z.wrappedValue.focus != nil {
                        Button("Follow cursor") { z.wrappedValue.focus = nil }
                    }
                    Text(String(format: "Duration %.2f s", z.wrappedValue.end - z.wrappedValue.start))
                        .font(.caption).foregroundStyle(.secondary)
                    Slider(value: z.scale, in: 1.2...4, onEditingChanged: editingChanged) { Text(String(format: "Zoom %.1f×", z.wrappedValue.scale)) }
                    Slider(value: z.start, in: 0...max(r.duration - 0.2, 0), onEditingChanged: editingChanged) { Text("Start \(timeString(z.wrappedValue.start))") }
                    Slider(value: z.end, in: 0...r.duration, onEditingChanged: editingChanged) { Text("End \(timeString(z.wrappedValue.end))") }
                    Button("Delete zoom", role: .destructive) {
                        project?.zooms.removeAll { $0.id == id }
                        selection = nil
                    }
                }
            }
        case .segment(let id):
            if let s = segmentBinding(id) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Clip \(timeString(s.wrappedValue.start)) – \(timeString(s.wrappedValue.end))")
                    Picker("Speed", selection: s.speed) {
                        ForEach([0.5, 1, 1.5, 2, 4], id: \.self) { Text("\($0.formatted())×").tag($0) }
                    }
                    Button("Delete clip", role: .destructive) {
                        deleteClip(id)
                    }
                    .disabled((project?.segments.count ?? 0) < 2)
                }
            }
        case nil:
            Text("Click a clip or a zoom in the timeline. Split clips with ⌘B, then delete or speed them up. Select a zoom and press ⌘B to split it at the playhead.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var focusOverlay: some View {
        if !pickingFocus, case .zoom(let id) = selection, let z = zoomBinding(id) {
            VStack {
                Spacer()
                HStack(spacing: 10) {
                    Button {
                        player.pause()
                        focusPreviewReady = false
                        pickingFocus = true
                    } label: { Image(systemName: "scope").frame(width: 26, height: 26) }
                    .buttonStyle(StudioToolbarButtonStyle())
                    .help("Choose zoom focus")
                    Slider(value: z.scale, in: 1.2...4, onEditingChanged: editingChanged)
                        .frame(maxWidth: 140).accessibilityLabel("Zoom strength")
                    Text(String(format: "%.1f×", z.wrappedValue.scale))
                        .font(.caption.monospacedDigit())
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(StudioTheme.line))
                .padding(12)
            }
        }
        if pickingFocus, let p = project, let r = recording, case .zoom(let id) = selection {
            GeometryReader { geo in
                ZStack(alignment: .top) {
                    Color.clear.contentShape(Rectangle())
                        .gesture(SpatialTapGesture().onEnded { tap in
                            guard focusPreviewReady,
                                  let focus = focusAtPreviewPoint(tap.location, size: geo.size,
                                      recording: r, project: p) else { return }
                            zoomBinding(id)?.wrappedValue.focus = focus
                            pickingFocus = false
                            focusPreviewReady = false
                            if let z = p.zooms.first(where: { $0.id == id }) {
                                let start = outputTime(atSource: z.start, p.segments)
                                let end = outputTime(atSource: z.end, p.segments)
                                seek(min(start + 0.5, (start + end) / 2))
                            }
                        })
                    Text(focusPreviewReady ? "Click the screen to set zoom focus" : "Preparing focus preview…")
                        .font(.system(size: 12, weight: .medium))
                        .padding(10).background(.regularMaterial, in: Capsule()).padding(12)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func zoomBinding(_ id: UUID) -> Binding<Zoom>? {
        guard let z = project?.zooms.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { project?.zooms.first { $0.id == id } ?? z },
            set: { new in
                guard let i = project?.zooms.firstIndex(where: { $0.id == id }) else { return }
                var v = new
                let duration = recording?.duration ?? v.end
                v.start = min(max(v.start, 0), max(duration - 0.2, 0))
                v.end = min(max(v.end, v.start + 0.2), duration)
                project?.zooms[i] = v
            })
    }

    private func segmentBinding(_ id: UUID) -> Binding<Segment>? {
        guard let s = project?.segments.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { project?.segments.first { $0.id == id } ?? s },
            set: { new in
                guard let i = project?.segments.firstIndex(where: { $0.id == id }) else { return }
                project?.segments[i] = new
            })
    }

    private func load() {
        do {
            let r = try readJSON(Recording.self, folder.appendingPathComponent("recording.json"))
            recording = r
            let loaded = (try? readJSON(Project.self, folder.appendingPathComponent("project.json"))) ?? Project(recording: r)
            history.reset(loaded)
            project = loaded
        } catch {
            status = "Could not open recording: \(error.localizedDescription)"
        }
    }

    private func editingChanged(_ editing: Bool) {
        guard let project else { return }
        if editing { history.begin(project) } else { history.end(project) }
    }

    private func undo() {
        guard let p = history.undo() else { return }
        project = p
    }

    private func redo() {
        guard let p = history.redo() else { return }
        project = p
    }

    private func applyTrim(_ clip: Segment) {
        guard var p = project, let i = p.segments.firstIndex(where: { $0.id == clip.id }) else { return }
        p.segments[i] = clip
        project = p
        selection = .segment(clip.id)
    }

    // Cancel superseded builds so fast edits cannot restore an older player item.
    private func rebuild() async {
        guard let r = recording, let p = project else { return }
        do {
            let choosing = pickingFocus
            var preview = p
            if choosing { preview.zooms = [] }
            let edit = try await buildEdit(folder: folder, recording: r, project: preview, renderSize: p.resolvedCanvas.format.size(shortEdge: 1080))
            guard !Task.isCancelled, project == p, pickingFocus == choosing else { return }
            let item = AVPlayerItem(asset: edit.composition)
            item.videoComposition = edit.videoComposition
            item.audioTimePitchAlgorithm = .spectral
            let wasPlaying = player.timeControlStatus == .playing
            let position = min(max(now, 0), outputDuration(p.segments))
            player.replaceCurrentItem(with: item)
            await player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            guard !Task.isCancelled, project == p, pickingFocus == choosing else { return }
            now = position
            focusPreviewReady = choosing
            if wasPlaying && !choosing { player.play() }
            buildError = nil
        } catch {
            guard !Task.isCancelled else { return }
            buildError = error.localizedDescription
        }
    }

    private func seek(_ t: Double) {
        now = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private var canDeleteSelection: Bool {
        guard let p = project else { return false }
        switch selection {
        case .segment(let id): return p.segments.count > 1 && p.segments.contains { $0.id == id }
        case .zoom(let id): return p.zooms.contains { $0.id == id }
        case nil: return false
        }
    }

    private func deleteSelection() {
        switch selection {
        case .segment(let id): deleteClip(id)
        case .zoom(let id):
            player.pause()
            project?.zooms.removeAll { $0.id == id }
            selection = nil
        case nil: break
        }
    }

    private func deleteClip(_ id: UUID) {
        guard let p = project, let edit = deletingSegment(in: p, id: id, playhead: now) else { return }
        player.pause()
        project = edit.project
        selection = nil
        seek(edit.playhead)
    }

    private func split() {
        player.pause()
        guard var p = project else { return }
        let src = sourceTime(atOutput: now, p.segments)
        // A selected zoom under the playhead splits instead of the clip.
        if case .zoom(let id) = selection, let cut = splittingZoom(p.zooms, id: id, at: src) {
            p.zooms = cut.zooms
            project = p
            selection = .zoom(cut.right)
            timelineFocused = true
            return
        }
        guard let i = p.segments.firstIndex(where: { src > $0.start + 0.05 && src < $0.end - 0.05 }) else { return }
        var right = p.segments[i]
        right.id = UUID()
        right.start = src
        p.segments[i].end = src
        p.segments.insert(right, at: i + 1)
        project = p
        selection = .segment(right.id)
        timelineFocused = true
    }

    private func addZoom() {
        guard let r = recording, var p = project else { return }
        player.pause()
        let src = min(sourceTime(atOutput: now, p.segments), max(0, r.duration - 0.2))
        let z = Zoom(start: src, end: min(src + 2.5, r.duration))
        p.zooms.append(z)
        project = p
        selection = .zoom(z.id)
    }

    private func export() {
        guard recording != nil, project != nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = folder.lastPathComponent + ".mp4"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        player.pause()
        startExport(to: url)
    }

    private func startExport(to url: URL) {
        guard let r = recording, let p = project else { return }
        let job = ExportJob(url: url, height: exportHeight, codec: codec, duration: outputDuration(p.segments), thumbnail: exportThumbnail())
        exportJob = job
        exportTask = Task {
            do {
                try await exportVideo(folder: folder, recording: r, project: p, height: job.height, codec: job.codec, to: url) { fraction in
                    Task { @MainActor in
                        guard exportJob?.id == job.id, case .running = exportJob?.phase else { return }
                        exportJob?.phase = .running(fraction)
                        setDockProgress(fraction)
                    }
                }
                let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if exportJob?.id == job.id { exportJob?.phase = .done(bytes: bytes) }
                if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
            } catch {
                if exportJob?.id == job.id, !Task.isCancelled { exportJob?.phase = .failed(error.localizedDescription) }
            }
            setDockProgress(nil)
        }
    }

    private func cancelExport() {
        exportTask?.cancel()
        exportTask = nil
        exportJob = nil
        setDockProgress(nil)
    }

    /// The current preview frame, with the full edit applied.
    private func exportThumbnail() -> NSImage? {
        guard let item = player.currentItem else { return nil }
        let generator = AVAssetImageGenerator(asset: item.asset)
        generator.videoComposition = item.videoComposition
        generator.maximumSize = CGSize(width: 480, height: 480)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        guard let cg = try? generator.copyCGImage(at: CMTime(seconds: now, preferredTimescale: 600), actualTime: nil) else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }

    private func setDockProgress(_ fraction: Double?) {
        NSApp.dockTile.badgeLabel = fraction.map { "\(Int(($0 * 100).rounded(.down)))%" }
    }
}

struct ExportJob: Equatable {
    enum Phase: Equatable { case running(Double), done(bytes: Int), failed(String) }
    let id = UUID()
    let url: URL
    let height: Double
    let codec: ExportCodec
    let duration: Double
    let started = Date()
    var thumbnail: NSImage?
    var phase = Phase.running(0)
}

/// Progress, result and errors for one export. Modal, so the project can't change mid-export.
struct ExportSheet: View {
    let job: ExportJob
    let cancel: () -> Void
    let retry: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                Group {
                    if let thumbnail = job.thumbnail { Image(nsImage: thumbnail).resizable().scaledToFit() }
                    else { Color.white.opacity(0.06) }
                }
                .frame(width: 120, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.08)))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title3.weight(.semibold))
                    Text(job.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Text("\(job.height == 2160 ? "4K" : "\(Int(job.height))p") · \(job.codec.rawValue) · 60 fps")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            switch job.phase {
            case .running(let fraction):
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: fraction)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        HStack {
                            Text("\(Int(fraction * 100))%").monospacedDigit()
                            Spacer()
                            Text(remaining(fraction, now: context.date))
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack { Spacer(); Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction) }
            case .done(let bytes):
                Label("\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) · \(clock(job.duration))",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                HStack {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([job.url]) }
                    Button("Open") { NSWorkspace.shared.open(job.url) }
                    Spacer()
                    Button("Done", action: close).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Close", action: close).keyboardShortcut(.cancelAction)
                    Button("Try again", action: retry).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 440)
        .interactiveDismissDisabled()
    }

    private var title: String {
        switch job.phase {
        case .running: return "Exporting…"
        case .done: return "Exported"
        case .failed: return "Export failed"
        }
    }

    private func clock(_ t: Double) -> String { String(format: "%d:%02d", Int(t) / 60, Int(t) % 60) }

    // Linear estimate from progress so far; hidden until there's enough to go on.
    private func remaining(_ fraction: Double, now: Date) -> String {
        let elapsed = now.timeIntervalSince(job.started)
        guard fraction > 0.03, elapsed > 1 else { return "Estimating time…" }
        let left = elapsed / fraction * (1 - fraction)
        return left < 60 ? "About \(max(1, Int(left.rounded()))) s left" : "About \(Int((left / 60).rounded(.up))) min left"
    }
}

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .none
        return v
    }
    func updateNSView(_ nsView: AVPlayerView, context: Context) {}
}

func timeString(_ t: Double) -> String {
    let t = max(t, 0)
    return String(format: "%d:%05.2f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
}

func hexColor(_ hex: Binding<String>) -> Binding<Color> {
    Binding(
        get: { let c = ciColor(hex: hex.wrappedValue); return Color(red: c.red, green: c.green, blue: c.blue) },
        set: { color in
            let n = NSColor(color).usingColorSpace(.sRGB) ?? .black
            hex.wrappedValue = String(format: "#%02X%02X%02X", Int(n.redComponent * 255), Int(n.greenComponent * 255), Int(n.blueComponent * 255))
        })
}
