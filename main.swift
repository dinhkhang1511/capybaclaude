// main.swift — Dino: a floating Claude Code companion for macOS
// Build: ./build.sh   (or: swiftc -O main.swift -o dino && ./dino)

import AppKit
import SwiftUI
import Network
import CoreAudio
import ApplicationServices

// MARK: - State

enum DinoState: String {
    case idle, working, waiting, done, error

    var badge: String? {
        switch self {
        case .idle:    return nil
        case .working: return "⚙️"
        case .waiting: return "✋"
        case .done:    return "✅"
        case .error:   return "💥"
        }
    }

    var tint: Color {
        switch self {
        case .idle:    return .secondary
        case .working: return .blue
        case .waiting: return .orange
        case .done:    return .green
        case .error:   return .red
        }
    }

    var systemSound: String? {
        switch self {
        case .done:    return "Glass"
        case .waiting: return "Ping"
        case .error:   return "Basso"
        default:       return nil
        }
    }
}

// MARK: - Sprite

/// Selectable character. Persisted in UserDefaults ("dino.skin").
enum Skin: String, CaseIterable {
    case capy, maomao, frieren, nezuko

    var title: String {
        switch self {
        case .capy:    return "Capybara"
        case .maomao:  return "MaoMao"
        case .frieren: return "Frieren"
        case .nezuko:  return "Nezuko"
        }
    }
}

/// One renderable sprite: a still image, a GIF (NSImageView plays it), or a
/// frame sequence sliced from a downloaded spritesheet (stepped by a timer).
enum SpriteAsset {
    case still(NSImage)
    case gif(NSImage)
    case frames([NSImage])

    var isStill: Bool { if case .still = self { return true }; return false }

    var previewImage: NSImage? {
        switch self {
        case .still(let i), .gif(let i): return i
        case .frames(let f):             return f.first
        }
    }
}

/// A pet downloaded from codex-pets.net, stored in Application Support.
struct Pet {
    let id: String
    let name: String
    let frames: [DinoState: [NSImage]]
    /// "Waving" row — played while music is on.
    let dance: [NSImage]?
}

/// Manages downloaded pets: ~/Library/Application Support/Dino/pets/<id>/
/// (spritesheet.webp + meta.json), sliced into frames at load time.
final class PetLibrary {
    static let shared = PetLibrary()
    private(set) var pets: [Pet] = []

    struct InstallError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dino/pets", isDirectory: true)
    }

    func pet(id: String) -> Pet? { pets.first { $0.id == id } }

    func reload() {
        let fm = FileManager.default
        var out: [Pet] = []
        for sub in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            let sheet = sub.appendingPathComponent("spritesheet.webp")
            guard fm.fileExists(atPath: sheet.path), let sliced = Self.slice(sheet) else { continue }
            var name = sub.lastPathComponent
            if let d = try? Data(contentsOf: sub.appendingPathComponent("meta.json")),
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: String],
               let n = obj["name"] { name = n }
            out.append(Pet(id: sub.lastPathComponent, name: name,
                           frames: sliced.frames, dance: sliced.dance))
        }
        pets = out.sorted { $0.name < $1.name }
    }

    /// Accepts any URL/text containing "pets/<id>" (e.g. codex-pets.net/#/pets/totoro),
    /// fetches the pet via the site's API and installs its spritesheet.
    func install(from link: String) async throws -> Pet {
        guard let r = link.range(of: "pets/([A-Za-z0-9_-]+)", options: .regularExpression) else {
            throw InstallError(message: "Link không đúng dạng codex-pets.net/#/pets/<id>")
        }
        let id = String(link[r].dropFirst("pets/".count))
        guard let api = URL(string: "https://codex-pets.net/api/pets/\(id)") else {
            throw InstallError(message: "Pet id không hợp lệ")
        }
        let (data, _) = try await URLSession.shared.data(from: api)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let petObj = obj["pet"] as? [String: Any],
              let sheetStr = petObj["spritesheetUrl"] as? String,
              let sheetURL = URL(string: sheetStr) else {
            throw InstallError(message: "Không tìm thấy pet \"\(id)\" trên codex-pets.net")
        }
        let (sheet, _) = try await URLSession.shared.data(from: sheetURL)

        let petDir = dir.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: petDir, withIntermediateDirectories: true)
        try sheet.write(to: petDir.appendingPathComponent("spritesheet.webp"))
        let name = (petObj["displayName"] as? String) ?? id
        try JSONSerialization.data(withJSONObject: ["id": id, "name": name])
            .write(to: petDir.appendingPathComponent("meta.json"))

        reload()
        guard let pet = pet(id: id) else {
            throw InstallError(message: "Spritesheet không đúng chuẩn 192×208 của codex-pets")
        }
        return pet
    }

    /// Standard codex-pets atlas: 8×9 grid of 192×208 cells. Rows used:
    /// idle=0(6f), waving=3(4f)→dance, jumping=4(5f)→done, failed=5(8f)→error,
    /// waiting=6(6f), review=8(6f)→working.
    private static func slice(_ url: URL) -> (frames: [DinoState: [NSImage]], dance: [NSImage]?)? {
        guard let img = NSImage(contentsOf: url),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil),
              cg.width >= 1536, cg.height >= 1872 else { return nil }
        let cw = 192, ch = 208

        func row(_ index: Int, _ count: Int) -> [NSImage] {
            var frames: [NSImage] = []
            for i in 0..<count {
                let rect = CGRect(x: i * cw, y: index * ch, width: cw, height: ch)
                if let c = cg.cropping(to: rect) {
                    frames.append(NSImage(cgImage: c, size: NSSize(width: cw, height: ch)))
                }
            }
            return frames
        }

        let rows: [(DinoState, Int, Int)] = [(.idle, 0, 6), (.done, 4, 5), (.error, 5, 8),
                                             (.waiting, 6, 6), (.working, 8, 6)]
        var out: [DinoState: [NSImage]] = [:]
        for (state, index, count) in rows {
            let frames = row(index, count)
            if !frames.isEmpty { out[state] = frames }
        }
        guard out[.idle] != nil else { return nil }
        let dance = row(3, 4)
        return (out, dance.isEmpty ? nil : dance)
    }
}

/// Sprite images, resolved once at launch.
/// Lookup order per file: env override → app bundle Resources → next to the
/// executable. Falls back to the 🦖 emoji when nothing exists.
enum Sprite {
    static let capyIdle    = find(envKey: "DINO_IMAGE", fileNames: ["dino.png"])
    static let capyWorking = find(envKey: "DINO_WORKING_IMAGE", fileNames: ["dino-working.gif"])

    static let maomaoIdle    = find(fileNames: ["maomao-idle.gif", "maomao/maomao-kusuriya-idle.gif"])
    static let maomaoWorking = find(fileNames: ["maomao-review.gif", "maomao/maomao-kusuriya-review.gif"])
    static let maomaoDone    = find(fileNames: ["maomao-jumping.gif", "maomao/maomao-kusuriya-jumping.gif"])

    static let frierenIdle    = find(fileNames: ["frieren-idle.gif", "frieren/frieren-idle.gif"])
    static let frierenWorking = find(fileNames: ["frieren-review.gif", "frieren/frieren-review.gif"])
    static let frierenDone    = find(fileNames: ["frieren-jumping.gif", "frieren/frieren-jumping.gif"])
    static let frierenWaiting = find(fileNames: ["frieren-waiting.gif", "frieren/frieren-waiting.gif"])
    static let frierenError   = find(fileNames: ["frieren-failed.gif", "frieren/frieren-failed.gif"])

    static let nezukoIdle    = find(fileNames: ["nezuko-idle.gif", "nezuko/nezuko-idle.gif"])
    static let nezukoWorking = find(fileNames: ["nezuko-running.gif", "nezuko/nezuko-running.gif"])
    static let nezukoDone    = find(fileNames: ["nezuko-jumping.gif", "nezuko/nezuko-jumping.gif"])
    static let nezukoWaiting = find(fileNames: ["nezuko-waiting.gif", "nezuko/nezuko-waiting.gif"])
    static let nezukoError   = find(fileNames: ["nezuko-failed.gif", "nezuko/nezuko-failed.gif"])

    /// Sprite for a skin id (built-in Skin rawValue or downloaded pet id) + state.
    static func asset(skinID: String, state: DinoState) -> SpriteAsset? {
        if let pet = PetLibrary.shared.pet(id: skinID) {
            if let f = pet.frames[state] ?? pet.frames[.idle], !f.isEmpty { return .frames(f) }
            return asset(skinID: Skin.capy.rawValue, state: state)
        }
        switch Skin(rawValue: skinID) ?? .capy {
        case .capy:
            if state == .working, let g = capyWorking { return .gif(g) }
            if let i = capyIdle { return .still(i) }
            return nil
        case .maomao:
            let gif: NSImage?
            switch state {
            case .working: gif = maomaoWorking ?? maomaoIdle
            case .done:    gif = maomaoDone ?? maomaoIdle
            default:       gif = maomaoIdle
            }
            if let g = gif { return .gif(g) }
            return asset(skinID: Skin.capy.rawValue, state: state)
        case .frieren:
            let gif: NSImage?
            switch state {
            case .working: gif = frierenWorking ?? frierenIdle
            case .done:    gif = frierenDone ?? frierenIdle
            case .waiting: gif = frierenWaiting ?? frierenIdle
            case .error:   gif = frierenError ?? frierenIdle
            case .idle:    gif = frierenIdle
            }
            if let g = gif { return .gif(g) }
            return asset(skinID: Skin.capy.rawValue, state: state)
        case .nezuko:
            let gif: NSImage?
            switch state {
            case .working: gif = nezukoWorking ?? nezukoIdle
            case .done:    gif = nezukoDone ?? nezukoIdle
            case .waiting: gif = nezukoWaiting ?? nezukoIdle
            case .error:   gif = nezukoError ?? nezukoIdle
            case .idle:    gif = nezukoIdle
            }
            if let g = gif { return .gif(g) }
            return asset(skinID: Skin.capy.rawValue, state: state)
        }
    }

    /// Sprite played while music is on: the "waving" row for downloaded pets,
    /// the bounciest GIF each built-in skin has.
    static func danceAsset(skinID: String) -> SpriteAsset? {
        if let pet = PetLibrary.shared.pet(id: skinID) {
            if let d = pet.dance, !d.isEmpty { return .frames(d) }
            return asset(skinID: skinID, state: .done)
        }
        let gif: NSImage?
        switch Skin(rawValue: skinID) ?? .capy {
        case .capy:    gif = capyWorking
        case .maomao:  gif = maomaoDone
        case .frieren: gif = frierenDone
        case .nezuko:  gif = nezukoDone
        }
        if let g = gif { return .gif(g) }
        return asset(skinID: skinID, state: .idle)
    }

    /// Small copy for the menu bar (status items want ~18 pt).
    static func statusIcon(for skinID: String) -> NSImage? {
        guard let img = asset(skinID: skinID, state: .idle)?.previewImage,
              let copy = img.copy() as? NSImage else { return nil }
        copy.size = NSSize(width: 18, height: 18)
        return copy
    }

    private static func find(envKey: String? = nil, fileNames: [String]) -> NSImage? {
        var candidates: [URL] = []
        if let envKey,
           let p = ProcessInfo.processInfo.environment[envKey], !p.isEmpty {
            candidates.append(URL(fileURLWithPath: (p as NSString).expandingTildeInPath))
        }
        for name in fileNames {
            if let res = Bundle.main.resourceURL {
                candidates.append(res.appendingPathComponent(name))
            }
            candidates.append(Bundle.main.bundleURL.deletingLastPathComponent()
                .appendingPathComponent(name))
        }
        for url in candidates {
            if let img = NSImage(contentsOf: url), img.isValid { return img }
        }
        return nil
    }
}

// MARK: - Music

/// System-wide media keys. macOS requires Accessibility permission to post
/// these; without it the events are silently dropped.
enum MediaKey {
    static let play: Int32 = 16      // NX_KEYTYPE_PLAY
    static let next: Int32 = 17      // NX_KEYTYPE_NEXT
    static let previous: Int32 = 18  // NX_KEYTYPE_PREVIOUS

    static var trusted: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func requestTrust() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func post(_ key: Int32) {
        for down in [true, false] {
            let raw = down ? 0xA00 : 0xB00
            guard let ev = NSEvent.otherEvent(with: .systemDefined,
                                              location: .zero,
                                              modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(raw)),
                                              timestamp: 0, windowNumber: 0, context: nil,
                                              subtype: 8,
                                              data1: Int((key << 16) | Int32(raw)),
                                              data2: -1) else { continue }
            ev.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}

/// Watches what's playing: CoreAudio tells us *whether* sound is coming out
/// (no permission needed, works for any app), AppleScript tells us *what*
/// (Spotify / Music / a YouTube tab in Chrome — needs Automation permission).
///
/// MediaRemote — the real system-wide now-playing API — is entitlement-gated
/// since macOS 15.4 and returns nothing to unsigned apps, hence this split.
final class NowPlayingMonitor {
    /// (isPlaying, "Title — Artist")
    var onUpdate: ((Bool, String?) -> Void)?

    private var timer: Timer?
    private let queue = DispatchQueue(label: "dino.nowplaying")
    private var lastTrackPoll = Date.distantPast
    private var lastTrack: String?

    func start() {
        stop()
        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
        t.tolerance = 0.3
        timer = t
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lastTrack = nil
        onUpdate?(false, nil)
    }

    private func poll() {
        queue.async { [weak self] in
            guard let self else { return }
            let playing = Self.audioIsRunning()
            // AppleScript is comparatively expensive — only while sound plays,
            // and at most every 5s.
            if playing, Date().timeIntervalSince(self.lastTrackPoll) > 5 {
                self.lastTrackPoll = Date()
                self.lastTrack = Self.currentTrack()
            } else if !playing {
                self.lastTrack = nil
            }
            let track = self.lastTrack
            DispatchQueue.main.async { self.onUpdate?(playing, track) }
        }
    }

    /// True when the default output device is actively rendering audio.
    private static func audioIsRunning() -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &dev) == noErr else { return false }
        var running = UInt32(0)
        var rAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                               mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
        size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(dev, &rAddr, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    /// AppleScript resolves an app's vocabulary at *compile* time, so a script
    /// mentioning an app that isn't installed fails to parse — and would take
    /// every other player down with it. Hence one script per player, compiled
    /// only when that app actually exists. Each guards on "is running" so we
    /// never launch a player just to ask what it's doing.
    private struct Player {
        let bundleID: String
        let source: String
    }

    private static let players: [Player] = [
        Player(bundleID: "com.spotify.client", source: """
        if application "Spotify" is running then
            tell application "Spotify"
                if player state is playing then
                    return (name of current track) & " — " & (artist of current track)
                end if
            end tell
        end if
        return ""
        """),
        Player(bundleID: "com.apple.Music", source: """
        if application "Music" is running then
            tell application "Music"
                if player state is playing then
                    return (name of current track) & " — " & (artist of current track)
                end if
            end tell
        end if
        return ""
        """),
        Player(bundleID: "com.google.Chrome", source: """
        if application "Google Chrome" is running then
            tell application "Google Chrome"
                try
                    set t to title of active tab of window 1
                    if t ends with " - YouTube" then return text 1 thru -11 of t
                end try
                repeat with w in windows
                    repeat with tb in tabs of w
                        set t to title of tb
                        if t ends with " - YouTube" then return text 1 thru -11 of t
                    end repeat
                end repeat
            end tell
        end if
        return ""
        """),
    ]

    private static let installedPlayers: [Player] = players.filter {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil
    }

    /// Runs on `queue`; each NSAppleScript is created fresh per call and never
    /// touched from two threads at once.
    private static func currentTrack() -> String? {
        for p in installedPlayers {
            guard let s = NSAppleScript(source: p.source) else { continue }
            var err: NSDictionary?
            let out = s.executeAndReturnError(&err).stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let err {
                NSLog("dino: now-playing (\(p.bundleID)) failed: \(err)")
                continue
            }
            if let out, !out.isEmpty {
                return out.count > 90 ? String(out.prefix(90)) + "…" : out
            }
        }
        return nil
    }
}

// MARK: - Model

final class DinoModel: ObservableObject {
    /// Built-in Skin rawValue or a downloaded pet id.
    @Published var skinID: String =
        UserDefaults.standard.string(forKey: "dino.skin") ?? Skin.capy.rawValue {
        didSet { UserDefaults.standard.set(skinID, forKey: "dino.skin") }
    }
    @Published var spriteSize: CGFloat = {
        let s = UserDefaults.standard.double(forKey: "dino.size")
        return s > 0 ? CGFloat(s) : 56
    }() {
        didSet { UserDefaults.standard.set(Double(spriteSize), forKey: "dino.size") }
    }
    @Published var state: DinoState = .idle
    @Published var title: String = "Claude Code"
    @Published var message: String = ""
    @Published var bubbleVisible: Bool = false

    @Published var musicEnabled: Bool =
        UserDefaults.standard.object(forKey: "dino.music") as? Bool ?? true {
        didSet { UserDefaults.standard.set(musicEnabled, forKey: "dino.music") }
    }
    @Published var musicPlaying: Bool = false
    @Published var nowPlaying: String?
    @Published var moveMode: Bool = false

    /// The pet dances only while Claude itself has nothing to say.
    var isDancing: Bool { musicEnabled && musicPlaying && state == .idle }

    private var hideWork: DispatchWorkItem?

    /// Announces a track — never on top of a live Claude message.
    func pushMusic(_ track: String) {
        DispatchQueue.main.async {
            guard self.state == .idle else { return }
            self.hideWork?.cancel()
            self.title = "🎵 Đang phát"
            self.message = track
            withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) {
                self.bubbleVisible = true
            }
            let w = DispatchWorkItem { [weak self] in
                guard let self else { return }
                withAnimation(.easeOut(duration: 0.25)) { self.bubbleVisible = false }
            }
            self.hideWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: w)
        }
    }

    /// ttl == 0 means "stay until the next event"
    func push(state: DinoState, title: String, message: String, ttl: TimeInterval) {
        DispatchQueue.main.async {
            self.hideWork?.cancel()
            self.state = state
            self.title = title
            self.message = message
            withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) {
                self.bubbleVisible = !message.isEmpty
            }
            if let s = state.systemSound { NSSound(named: s)?.play() }

            guard ttl > 0 else { return }
            let w = DispatchWorkItem { [weak self] in
                guard let self else { return }
                withAnimation(.easeOut(duration: 0.25)) { self.bubbleVisible = false }
                self.state = .idle
            }
            self.hideWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + ttl, execute: w)
        }
    }

    func dismiss() {
        DispatchQueue.main.async {
            self.hideWork?.cancel()
            withAnimation(.easeOut(duration: 0.2)) { self.bubbleVisible = false }
            self.state = .idle
        }
    }
}

// MARK: - View

/// NSImageView is an NSControl: it swallows mouse-down and reports
/// mouseDownCanMoveWindow = false, which blocks the panel's
/// isMovableByWindowBackground drag. Make it transparent to the mouse.
final class PassthroughImageView: NSImageView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Transparent hit area over the sprite: click = play/pause, scroll = skip.
/// Goes inert in Move mode so the window drag keeps working.
final class PetInteractionNSView: NSView {
    var onClick: () -> Void = {}
    var onScroll: (CGFloat) -> Void = { _ in }
    var active = true

    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { active ? super.hitTest(point) : nil }
    override func mouseDown(with event: NSEvent) { onClick() }
    override func scrollWheel(with event: NSEvent) { onScroll(event.scrollingDeltaY) }
}

struct PetInteractionView: NSViewRepresentable {
    let active: Bool
    let onClick: () -> Void
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> PetInteractionNSView {
        let v = PetInteractionNSView()
        updateNSView(v, context: context)
        return v
    }

    func updateNSView(_ v: PetInteractionNSView, context: Context) {
        v.active = active
        v.onClick = onClick
        v.onScroll = onScroll
    }
}

/// SwiftUI's Image renders only the first frame of a GIF; NSImageView plays it.
struct AnimatedImageView: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> PassthroughImageView {
        let v = PassthroughImageView()
        v.image = image
        v.animates = true
        v.imageScaling = .scaleProportionallyUpOrDown
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return v
    }

    func updateNSView(_ v: PassthroughImageView, context: Context) {
        // State/skin switches swap the GIF — restart animation on the new one.
        if v.image !== image {
            v.image = image
            v.animates = true
        }
    }
}

/// Plays a sliced spritesheet row by stepping frames at ~8 fps.
struct FrameAnimationView: View {
    let frames: [NSImage]
    @State private var idx = 0
    private let timer = Timer.publish(every: 0.125, on: .main, in: .common).autoconnect()

    var body: some View {
        Image(nsImage: frames[min(idx, frames.count - 1)])
            .resizable()
            .interpolation(.none)
            .scaledToFit()
            .onReceive(timer) { _ in idx = (idx + 1) % frames.count }
    }
}

struct DinoOverlay: View {
    @ObservedObject var model: DinoModel
    var onPetClick: () -> Void = {}
    var onPetScroll: (CGFloat) -> Void = { _ in }
    @State private var bob = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            Spacer(minLength: 0)
            if model.bubbleVisible {
                bubble.transition(.move(edge: .trailing).combined(with: .opacity))
            }
            dino
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .onAppear { bob = true }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(model.state.tint).frame(width: 7, height: 7)
                Text(model.title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(model.message)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .lineLimit(5)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 320, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 14, y: 5)
    }

    private var currentAsset: SpriteAsset? {
        model.isDancing ? Sprite.danceAsset(skinID: model.skinID)
                        : Sprite.asset(skinID: model.skinID, state: model.state)
    }

    @ViewBuilder
    private var sprite: some View {
        switch currentAsset {
        case .some(.gif(let img)):
            AnimatedImageView(image: img)
                .frame(width: model.spriteSize, height: model.spriteSize)
        case .some(.still(let img)):
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: model.spriteSize, height: model.spriteSize)
        case .some(.frames(let arr)):
            FrameAnimationView(frames: arr)
                .frame(width: model.spriteSize, height: model.spriteSize)
                // restart the row's animation whenever the row changes
                .id("\(model.state.rawValue)-\(model.isDancing)")
        case .none:
            Text("🦖")
                .font(.system(size: model.spriteSize * 0.9))
        }
    }

    private var dino: some View {
        ZStack(alignment: .topTrailing) {
            sprite
                // GIFs/frame sequences animate by themselves — no wobble on top.
                .rotationEffect(.degrees((currentAsset?.isStill ?? false)
                                         ? (model.state == .working ? (bob ? -7 : 7) : (bob ? -2 : 2))
                                         : 0),
                                anchor: .bottom)
                .offset(y: bob ? -5 : 0)
                .animation(
                    .easeInOut(duration: model.state == .working ? 0.32 : 1.4)
                        .repeatForever(autoreverses: true),
                    value: bob
                )
                .animation(.easeInOut(duration: 0.3), value: model.state)

            if let badge = model.state.badge {
                Text(badge)
                    .font(.system(size: max(17, model.spriteSize * 0.3)))
                    .offset(x: model.spriteSize * 0.14, y: -model.spriteSize * 0.1)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .opacity(model.state == .idle && !model.bubbleVisible && !model.isDancing ? 0.35 : 1)
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        .frame(width: model.spriteSize + 18, height: model.spriteSize + 18, alignment: .bottom)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: model.spriteSize)
        .overlay(PetInteractionView(active: !model.moveMode,
                                    onClick: onPetClick,
                                    onScroll: onPetScroll))
    }
}

// MARK: - Tiny localhost HTTP server

final class HookServer {
    private let onPayload: ([String: Any]) -> Void
    private let queue = DispatchQueue(label: "dino.http")
    private var listener: NWListener?

    init(onPayload: @escaping ([String: Any]) -> Void) { self.onPayload = onPayload }

    func start(port: UInt16) {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1",
                                                 port: NWEndpoint.Port(rawValue: port)!)
        do {
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.start(queue: queue)
            listener = l
            NSLog("dino: listening on 127.0.0.1:\(port)")
        } catch {
            NSLog("dino: cannot bind port \(port): \(error)")
        }
    }

    private final class Box { var data = Data() }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        let box = Box()

        func step() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 18) { [weak self] chunk, _, done, err in
                guard let self else { conn.cancel(); return }
                if let c = chunk, !c.isEmpty { box.data.append(c) }

                if let body = HookServer.completeBody(box.data) {
                    if !body.isEmpty,
                       let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                        self.onPayload(obj)
                    }
                    self.reply(conn)
                    return
                }
                if done || err != nil { self.reply(conn); return }
                step()
            }
        }
        step()
    }

    /// Returns the body once the full request has arrived, else nil.
    private static func completeBody(_ raw: Data) -> Data? {
        guard let sep = raw.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: raw[..<sep.lowerBound], as: UTF8.self)
        var length = 0
        for line in head.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                length = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let body = raw[sep.upperBound...]
        guard body.count >= length else { return nil }
        return length == 0 ? Data() : Data(body.prefix(length))
    }

    // Claude Code treats a non-2xx or non-empty body as a hook error, so: 200 + empty.
    private func reply(_ conn: NWConnection) {
        let head = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8), completion: .contentProcessed { _ in conn.cancel() })
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = DinoModel()
    private var panel: NSPanel!
    private var statusItem: NSStatusItem!
    private var server: HookServer!
    private var moveMode = false
    private let music = NowPlayingMonitor()
    private var hoverTimer: Timer?
    private var scrollAccum: CGFloat = 0
    private var lastSkip = Date.distantPast
    private var askedForTrust = false

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)      // no Dock icon
        PetLibrary.shared.reload()
        buildPanel()
        buildStatusItem()
        startMusicMonitor()
        startHoverTracking()

        let port = UInt16(ProcessInfo.processInfo.environment["DINO_PORT"] ?? "") ?? 7654
        server = HookServer { [weak self] payload in self?.handle(payload) }
        server.start(port: port)

        model.push(state: .done, title: "Dino", message: "Sẵn sàng — 127.0.0.1:\(port)", ttl: 4)
    }

    // MARK: window

    private func buildPanel() {
        let size = NSSize(width: 470, height: 190)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
        p.isFloatingPanel = true
        p.level = .screenSaver                     // above full-screen Chrome etc.
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.worksWhenModal = true
        p.isMovableByWindowBackground = true
        p.ignoresMouseEvents = true                // click-through by default
        p.contentView = NSHostingView(rootView: DinoOverlay(
            model: model,
            onPetClick: { [weak self] in self?.petClicked() },
            onPetScroll: { [weak self] dy in self?.petScrolled(dy) }))
        panel = p
        applyPosition()
        p.orderFrontRegardless()
    }

    private var corner: Int {
        get { UserDefaults.standard.object(forKey: "dino.corner") as? Int ?? 3 }
        set { UserDefaults.standard.set(newValue, forKey: "dino.corner") }
    }

    private func applyPosition() {
        guard let screen = NSScreen.main else { return }
        let v = screen.visibleFrame
        let s = panel.frame.size
        let m: CGFloat = 10
        let left = (corner == 0 || corner == 2)
        let top  = (corner == 0 || corner == 1)
        panel.setFrameOrigin(NSPoint(
            x: left ? v.minX + m : v.maxX - s.width - m,
            y: top  ? v.maxY - s.height - m : v.minY + m
        ))
    }

    // MARK: music

    private func startMusicMonitor() {
        music.onUpdate = { [weak self] playing, track in
            guard let self else { return }
            // Announce on a new track, and again when sound resumes after silence.
            let resumed = playing && !self.model.musicPlaying
            let changed = self.model.nowPlaying != track
            self.model.musicPlaying = playing
            self.model.nowPlaying = track
            if let track, playing, self.model.musicEnabled, changed || resumed {
                self.model.pushMusic(track)
            }
        }
        if model.musicEnabled { music.start() }
    }

    /// The panel stays click-through except while the cursor sits on the pet,
    /// so the music controls never swallow a click meant for the app below.
    private func startHoverTracking() {
        let t = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self, let panel = self.panel, !self.moveMode else { return }
            let over = self.petScreenRect().contains(NSEvent.mouseLocation)
            if panel.ignoresMouseEvents == over { panel.ignoresMouseEvents = !over }
        }
        t.tolerance = 0.05
        hoverTimer = t
    }

    /// Where the sprite sits on screen — bottom-trailing of the panel, matching
    /// DinoOverlay's 14pt padding and spriteSize + 18 box.
    private func petScreenRect() -> NSRect {
        let f = panel.frame
        let box = model.spriteSize + 18
        let pad: CGFloat = 14
        return NSRect(x: f.maxX - pad - box, y: f.minY + pad, width: box, height: box)
    }

    private func petClicked() {
        guard ensureMediaTrust() else { return }
        MediaKey.post(MediaKey.play)
    }

    private func petScrolled(_ dy: CGFloat) {
        scrollAccum += dy
        guard abs(scrollAccum) > 12, Date().timeIntervalSince(lastSkip) > 0.6 else { return }
        let up = scrollAccum > 0
        scrollAccum = 0
        lastSkip = Date()
        guard ensureMediaTrust() else { return }
        MediaKey.post(up ? MediaKey.next : MediaKey.previous)
        model.push(state: .idle, title: "🎵 Dino",
                   message: up ? "Bài kế tiếp ⏭" : "Bài trước ⏮", ttl: 2)
    }

    /// Posting media keys needs Accessibility — ask once, then point at the
    /// exact System Settings pane instead of failing silently.
    private func ensureMediaTrust() -> Bool {
        if MediaKey.trusted { return true }
        // Ask (and open System Settings) at most once per launch — nagging on
        // every click would be worse than doing nothing.
        if !askedForTrust {
            askedForTrust = true
            MediaKey.requestTrust()
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
        model.push(state: .waiting, title: "Dino",
                   message: "Cần quyền Accessibility để điều khiển nhạc — bật Dino trong "
                          + "System Settings → Privacy & Security → Accessibility.",
                   ttl: 14)
        return false
    }

    // MARK: menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        applyStatusIcon()
        statusItem.menu = makeMenu()
    }

    private func applyStatusIcon() {
        if let icon = Sprite.statusIcon(for: model.skinID) {
            statusItem.button?.image = icon
            statusItem.button?.title = ""
        } else {
            statusItem.button?.image = nil
            statusItem.button?.title = "🦖"
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        let test = NSMenuItem(title: "Test bubble", action: #selector(testBubble), keyEquivalent: "")
        test.target = self
        menu.addItem(test)

        let move = NSMenuItem(title: "Move mode (kéo dino)", action: #selector(toggleMove), keyEquivalent: "")
        move.target = self
        move.state = moveMode ? .on : .off
        menu.addItem(move)

        let musicItem = NSMenuItem(title: "🎵 Theo nhạc đang phát",
                                   action: #selector(toggleMusic(_:)), keyEquivalent: "")
        musicItem.target = self
        musicItem.state = model.musicEnabled ? .on : .off
        menu.addItem(musicItem)

        let posItem = NSMenuItem(title: "Vị trí", action: nil, keyEquivalent: "")
        let pos = NSMenu()
        for (i, name) in ["Trên – trái", "Trên – phải", "Dưới – trái", "Dưới – phải"].enumerated() {
            let it = NSMenuItem(title: name, action: #selector(setCorner(_:)), keyEquivalent: "")
            it.tag = i
            it.target = self
            it.state = (i == corner) ? .on : .off
            pos.addItem(it)
        }
        menu.addItem(posItem)
        menu.setSubmenu(pos, for: posItem)

        let skinItem = NSMenuItem(title: "Nhân vật", action: nil, keyEquivalent: "")
        let skins = NSMenu()
        var entries: [(id: String, title: String)] = Skin.allCases.map { ($0.rawValue, $0.title) }
        entries += PetLibrary.shared.pets.map { ($0.id, $0.name) }
        for (id, title) in entries {
            let it = NSMenuItem(title: title, action: #selector(setSkin(_:)), keyEquivalent: "")
            it.representedObject = id
            it.target = self
            it.state = (id == model.skinID) ? .on : .off
            skins.addItem(it)
        }
        skins.addItem(.separator())
        let add = NSMenuItem(title: "Thêm pet từ link…", action: #selector(addPetFromLink), keyEquivalent: "")
        add.target = self
        skins.addItem(add)
        menu.addItem(skinItem)
        menu.setSubmenu(skins, for: skinItem)

        let sizeItem = NSMenuItem(title: "Kích thước", action: nil, keyEquivalent: "")
        let sizes = NSMenu()
        for (name, pts) in [("Nhỏ", 56), ("Vừa", 80), ("Lớn", 110), ("Bự", 150)] {
            let it = NSMenuItem(title: "\(name) (\(pts)pt)", action: #selector(setSize(_:)), keyEquivalent: "")
            it.tag = pts
            it.target = self
            it.state = (CGFloat(pts) == model.spriteSize) ? .on : .off
            sizes.addItem(it)
        }
        menu.addItem(sizeItem)
        menu.setSubmenu(sizes, for: sizeItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Dino", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    @objc private func testBubble() {
        model.push(state: .done, title: "promer / ai-photo",
                   message: "Đã fix xong pipeline render, 3 files changed.", ttl: 10)
    }

    @objc private func toggleMove(_ sender: NSMenuItem) {
        moveMode.toggle()
        model.moveMode = moveMode
        sender.state = moveMode ? .on : .off
        panel.ignoresMouseEvents = !moveMode
        model.push(state: .idle,
                   title: "Dino",
                   message: moveMode ? "Kéo dino tới chỗ bạn muốn, rồi tắt Move mode."
                                     : "Đã khoá lại (click-through).",
                   ttl: 4)
    }

    @objc private func setSkin(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        model.skinID = id
        statusItem.menu = makeMenu()
        applyStatusIcon()
        // .done doubles as a preview of the skin's "success" sprite.
        model.push(state: .done, title: "Dino", message: "Đã chuyển sang \(sender.title)!", ttl: 4)
    }

    @objc private func addPetFromLink() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Thêm pet từ codex-pets.net"
        alert.informativeText = "Dán link dạng https://codex-pets.net/#/pets/<id>"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "https://codex-pets.net/#/pets/totoro"
        if let pasted = NSPasteboard.general.string(forType: .string),
           pasted.contains("codex-pets.net") {
            field.stringValue = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Thêm")
        alert.addButton(withTitle: "Huỷ")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        installPet(from: field.stringValue)
    }

    private func installPet(from link: String) {
        model.push(state: .working, title: "Dino", message: "Đang tải pet…", ttl: 0)
        Task { @MainActor in
            do {
                let pet = try await PetLibrary.shared.install(from: link)
                model.skinID = pet.id
                statusItem.menu = makeMenu()
                applyStatusIcon()
                model.push(state: .done, title: "Dino", message: "Đã thêm \(pet.name)!", ttl: 5)
            } catch {
                model.push(state: .error, title: "Dino",
                           message: "Lỗi tải pet: \(error.localizedDescription)", ttl: 8)
            }
        }
    }

    @objc private func toggleMusic(_ sender: NSMenuItem) {
        model.musicEnabled.toggle()
        sender.state = model.musicEnabled ? .on : .off
        if model.musicEnabled { music.start() } else { music.stop() }
        model.push(state: .done, title: "Dino",
                   message: model.musicEnabled
                       ? "Pet sẽ nhảy theo nhạc. Click vào pet = play/pause, cuộn = đổi bài."
                       : "Đã tắt chế độ theo nhạc.",
                   ttl: 5)
    }

    @objc private func setSize(_ sender: NSMenuItem) {
        model.spriteSize = CGFloat(sender.tag)
        sender.menu?.items.forEach { $0.state = ($0.tag == sender.tag) ? .on : .off }
        model.push(state: .done, title: "Dino", message: "Kích thước: \(sender.tag)pt", ttl: 3)
    }

    @objc private func setCorner(_ sender: NSMenuItem) {
        corner = sender.tag
        sender.menu?.items.forEach { $0.state = ($0.tag == sender.tag) ? .on : .off }
        applyPosition()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: hook payloads

    private func handle(_ p: [String: Any]) {
        let event = (p["hook_event_name"] as? String) ?? "Custom"
        let project = (p["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? "Claude Code"

        switch event {
        case "UserPromptSubmit":
            model.push(state: .working, title: project, message: "Đang chạy…", ttl: 0)

        case "Notification":
            model.push(state: .waiting, title: project,
                       message: clean(p["message"] as? String) ?? "Cần bạn xác nhận", ttl: 0)

        case "Stop", "SubagentStop":
            model.push(state: .done, title: project,
                       message: clean(p["last_assistant_message"] as? String) ?? "Xong!", ttl: 15)

        case "StopFailure":
            model.push(state: .error, title: project,
                       message: clean(p["error_type"] as? String) ?? "Turn failed", ttl: 25)

        case "SessionEnd":
            model.dismiss()

        default: // custom POST /notify
            let st = DinoState(rawValue: (p["state"] as? String) ?? "done") ?? .done
            model.push(state: st,
                       title: (p["title"] as? String) ?? project,
                       message: clean(p["message"] as? String) ?? "",
                       ttl: (p["ttl"] as? Double) ?? 12)
        }
    }

    private func clean(_ s: String?) -> String? {
        guard let raw = s?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        var t = raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if t.count > 240 { t = String(t.prefix(240)) + "…" }
        return t
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
