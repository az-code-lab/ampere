// Renders the Ampere product introduction video: narration via the macOS
// speech synthesizer, frames via SwiftUI's ImageRenderer, H.264 + AAC via
// AVAssetWriter. Run through Video/make-video.sh, which first exports the
// panel renders this file composes (Tests/AmpereTests/VideoSnapshotTests).
//
//   IntroVideo --panels DIR --work DIR --out FILE [--out-4k FILE] [--voice NAME]
//              [--rate WPM] [--music FILE|none] [--music-dir DIR] [--stills]
//
// --out is the 1080p video, written with a poster (.jpg) and English
// captions (.en.vtt) beside it for the site's player; --out-4k adds a
// 3840x2160 rendering of the same frames from the same run.
// --voice is a name from `say -v ?` or "system" (the default) for the voice
// chosen in System Settings > Accessibility > Read & Speak; see systemVoice.
// The music under the narration is Music.digitalLemonade, fetched once
// into --music-dir (default Video/out/music) and credited on the closing
// card; --music names another of Music.known, a file of your own, or
// "none" for the narration alone. --stills writes three PNG frames per
// scene into WORK/stills instead of the video, for checking layout
// without waiting on the full render.

import AVFoundation
import AppKit
import CryptoKit
import SwiftUI

// MARK: - Script

/// One scene of the video: what is said and which layout illustrates it.
/// Scene length follows the narration: lead-in silence, the speech, then
/// a tail, never shorter than `minimum`.
struct Scene {
    enum Kind {
        case title, problem, bounds, telemetry, microcharge, onDemand, safety, extras, install, outro
    }
    let kind: Kind
    let narration: String
    var minimum: Double = 0
    var lead: Double = 0.8
    var tail: Double = 1.1
}

let script: [Scene] = [
    Scene(kind: .title,
          narration: "Meet Ampere. A menu bar battery manager for Apple Silicon Macs.",
          minimum: 7, lead: 1.4, tail: 1.4),
    Scene(kind: .problem,
          narration: "Lithium-ion batteries age fastest when they sit at one hundred percent, or drain near empty. A MacBook that lives on the charger spends most of its life at the top."),
    Scene(kind: .bounds,
          narration: "Ampere holds your battery in a healthy range instead. Pick a band, like forty to sixty percent. Charging starts at the bottom of the band, holds in the middle, and stops at the top. Automatically."),
    Scene(kind: .telemetry,
          narration: "The panel shows everything your battery wants you to know. Adapter, battery, and system wattage. Voltages, currents, temperature, cycle count, health, and battery age. A dozen readouts, always current."),
    Scene(kind: .microcharge,
          narration: "Between the bounds, charging stays off until you ask, even after a restart. Every cycle runs full, from the lower bound to the upper, with no fragmented top-ups."),
    Scene(kind: .onDemand,
          narration: "Heading out without a charger? Charge to Full tops the battery up in one tap, and normal management takes over again once the charge completes. Sitting above your upper bound? Discharge back down to it, even with the charger plugged in."),
    Scene(kind: .safety,
          // "resumes" is read as the noun by the Siri voice; keep the
          // narration to words with one pronunciation.
          narration: "Close the lid mid-charge, and Ampere pauses just before sleep and continues when your Mac wakes, so a charge never overshoots your bound. Quitting Ampere restores every system default. And if the app is ever force-killed, a watchdog puts your Mac back to normal within seconds."),
    Scene(kind: .extras,
          narration: "The menu bar icon shows your live charge level. Pin the panel open, or drag it off the menu bar and float it anywhere. Keep your Mac awake for a set time. Launch at login. Update right from the panel."),
    Scene(kind: .install,
          narration: "Install it with Homebrew, or download the disk image. Grant admin once, set your bounds, and forget about it. Ampere is free in the default forty to sixty percent range. A one-time license unlocks custom bounds."),
    Scene(kind: .outro,
          narration: "Ampere. Take charge of your battery. Get it at ampere battery dot app.",
          minimum: 7, lead: 1.0, tail: 2.6),
]

// MARK: - Timeline

struct Cue {
    let scene: Scene
    let start: Double
    let duration: Double
    let speechStart: Double
    let speechDuration: Double
    let audio: URL

    /// Narration progress, 0 before the first word and 1 after the last.
    func speech(_ t: Double) -> Double {
        clamp01((t - speechStart) / max(speechDuration, 0.01))
    }
}

let fps: Int32 = 30
let sampleRate = 48_000.0

/// The voice chosen in System Settings > Accessibility > Read & Speak
/// (Spoken Content before macOS 27), which `say` uses when no voice is
/// named. It is the only way to narrate with a Siri voice: `say` neither
/// lists Siri voices nor accepts their names.
let systemVoice = "system"

/// `say` silently falls back to Samantha for a name it does not know, so a
/// named voice is checked against its installed list first.
func checkVoice(_ voice: String) throws {
    guard voice != systemVoice else { return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    process.arguments = ["-v", "?"]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let listing = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    guard listing.split(separator: "\n").contains(where: { $0.hasPrefix(voice + " ") }) else {
        throw VideoError("voice \"\(voice)\" is not installed; `say -v ?` lists the installed voices, and \"\(systemVoice)\" uses the Read & Speak system voice")
    }
}

/// With a Siri voice, `say` now and then never exits even though the clip
/// is fully written (seen once in nine clips). A run whose output file has
/// stopped growing for 15 s is killed and the clip synthesized again.
func synthesize(_ text: String, voice: String, rate: Int?, to url: URL) throws {
    var arguments = ["-o", url.path, "--data-format=LEI16@\(Int(sampleRate))"]
    if voice != systemVoice { arguments += ["-v", voice] }
    if let rate { arguments += ["-r", String(rate)] }
    arguments.append(text)
    for attempt in 1...3 {
        try? FileManager.default.removeItem(at: url)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = arguments
        try process.run()
        var lastSize = -1
        var lastGrowth = Date()
        var stalled = false
        while process.isRunning {
            usleep(500_000)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if size != lastSize {
                lastSize = size
                lastGrowth = Date()
            } else if Date().timeIntervalSince(lastGrowth) > 15 {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
                stalled = true
                break
            }
        }
        if stalled {
            print("  say stalled after writing the clip (attempt \(attempt)), retrying")
            continue
        }
        guard process.terminationStatus == 0 else {
            throw VideoError("say failed for voice \(voice) (exit \(process.terminationStatus))")
        }
        return
    }
    throw VideoError("say stalled three times on: \(text.prefix(40))…")
}

struct VideoError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func buildTimeline(work: URL, voice: String, rate: Int?) throws -> [Cue] {
    try checkVoice(voice)
    var cues: [Cue] = []
    var clock = 0.0
    for (index, scene) in script.enumerated() {
        let audio = work.appendingPathComponent(String(format: "narration-%02d.caf", index))
        try synthesize(scene.narration, voice: voice, rate: rate, to: audio)
        let file = try AVAudioFile(forReading: audio)
        let speech = Double(file.length) / file.fileFormat.sampleRate
        // Whole frames, so the audio track and the frame count agree exactly.
        let frames = ceil(max(scene.minimum, scene.lead + speech + scene.tail) * Double(fps))
        let duration = frames / Double(fps)
        cues.append(Cue(scene: scene, start: clock, duration: duration,
                        speechStart: scene.lead, speechDuration: speech, audio: audio))
        clock += duration
    }
    return cues
}

// MARK: - Music

/// A track played low under the narration, the way the dbclient promos
/// carry one: where it is fetched from, how a download is known to be the
/// right file, and the credit its license asks for on the closing card.
struct Music {
    let title: String
    let artist: String
    let file: String
    let url: String
    let sha256: String
    let license: String
    let credit: String

    /// The tracks the dbclient promos wear, both Kevin MacLeod's and free
    /// under Creative Commons Attribution 4.0 with the credit on the
    /// closing card (Video/MUSIC-LICENSE.txt spells the terms out):
    /// "Digital Lemonade", bright analog synths over a light beat, under
    /// its product introduction and so the default here too; "Getting it
    /// Done", clean synths in a livelier dance groove, under its race-day
    /// film.
    static let digitalLemonade = Music(
        title: "Digital Lemonade", artist: "Kevin MacLeod", file: "Digital Lemonade.mp3",
        url: "https://incompetech.com/music/royalty-free/mp3-royaltyfree/Digital%20Lemonade.mp3",
        sha256: "be9f665efd035dea23a1e9539c534ba905f44144f7dda05a0a663ccecda1ab21",
        license: "Creative Commons: By Attribution 4.0",
        credit: "Music: Digital Lemonade by Kevin MacLeod (incompetech.com), CC BY 4.0")
    static let gettingItDone = Music(
        title: "Getting it Done", artist: "Kevin MacLeod", file: "Getting it Done.mp3",
        url: "https://incompetech.com/music/royalty-free/mp3-royaltyfree/Getting%20it%20Done.mp3",
        sha256: "bc74076ec1c263f6ac4634403d0acc1ccc5d2e79f2d083243e00d236b547c15b",
        license: "Creative Commons: By Attribution 4.0",
        credit: "Music: Getting it Done by Kevin MacLeod (incompetech.com), CC BY 4.0")
    static let known = [digitalLemonade, gettingItDone]

    /// The track in `folder`, fetched into it first when it is missing.
    /// Bytes whose SHA-256 is not the one recorded here are refused,
    /// whether they came from the download or were already in the folder.
    func fetched(into folder: URL) async throws -> URL {
        let path = folder.appendingPathComponent(file)
        let cached = FileManager.default.fileExists(atPath: path.path)
        let data: Data
        if cached {
            data = try Data(contentsOf: path)
        } else {
            print("Fetching \(title) from \(url)")
            let (downloaded, response) = try await URLSession.shared.data(from: URL(string: url)!)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw VideoError("download of \(url) failed")
            }
            data = downloaded
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == sha256 else {
            throw VideoError("\(cached ? path.path : url) is not \(title) by \(artist): SHA-256 \(digest)")
        }
        if !cached {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: path)
        }
        return path
    }
}

/// The soundtrack's music, if any, and the track it is when it is one
/// of Music.known, whose credit the closing card shows.
struct Soundtrack {
    let music: URL?
    let track: Music?
    var credit: String? { track?.credit }

    /// `--music none` for the narration alone; `--music TITLE` for one of
    /// Music.known; `--music FILE` for a track of your own (no credit);
    /// otherwise Music.digitalLemonade, fetched into `--music-dir`.
    static func resolve(_ options: [String: String]) async throws -> Soundtrack {
        let folder = URL(fileURLWithPath: options["--music-dir"] ?? "Video/out/music", isDirectory: true)
        guard let choice = options["--music"] else {
            return Soundtrack(music: try await Music.digitalLemonade.fetched(into: folder), track: Music.digitalLemonade)
        }
        if choice == "none" { return Soundtrack(music: nil, track: nil) }
        if let track = Music.known.first(where: { $0.title.caseInsensitiveCompare(choice) == .orderedSame }) {
            return Soundtrack(music: try await track.fetched(into: folder), track: track)
        }
        let file = URL(fileURLWithPath: choice)
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw VideoError("music \"\(choice)\" is neither a file nor one of: \(Music.known.map(\.title).joined(separator: ", "))")
        }
        return Soundtrack(music: file, track: nil)
    }
}

// MARK: - Soundtrack

/// The voice's loudest sample after normalization, and the bed's (RMS)
/// level: one steady level under the lines and between them, well under
/// the voice, and held there through the track's own quiet and loud
/// passages (see `levelled`). The dbclient promos sit their bed at the
/// same level; a bed that dipped under each line and came back between
/// them was found distracting there, so nothing ducks.
let voicePeak: Float = 0.8
let bedLevel: Float = 0.025
let bedFadeIn = 1.5
let bedFadeOut = 2.5
/// Seconds of track one level reading spans, and how long the gain takes
/// to follow a change in it.
let levelWindow = 2.0
let levelResponse = 1.0

/// The track at `level` moment to moment, not just on average: a slow
/// automatic gain rides its own quiet and loud passages so the bed's
/// level under the voice stays put (user, 2026-09-28: keep the music
/// volume constant). The gain follows the RMS of a `levelWindow`-second
/// window around each moment, eases over `levelResponse` seconds so
/// beats keep their punch, and stays within 12 dB of the track's average
/// gain so a silence is not pulled up into noise.
func levelled(_ track: [[Float]], to level: Float) -> [[Float]] {
    let frames = track[0].count
    guard frames > 0 else { return track }
    var prefix = [Double](repeating: 0, count: frames + 1)
    for index in 0..<frames {
        let power = track.reduce(0.0) { $0 + Double($1[index]) * Double($1[index]) } / Double(track.count)
        prefix[index + 1] = prefix[index] + power
    }
    let average = (prefix[frames] / Double(frames)).squareRoot()
    guard average > 0 else { return track }
    let averageGain = Double(level) / average
    let hop = Int(sampleRate * 0.05)
    let half = Int(sampleRate * levelWindow / 2)
    let ease = 0.05 / levelResponse
    var gains: [Double] = []
    var smoothed = averageGain
    var at = 0
    while at < frames {
        let start = max(0, at - half)
        let end = min(frames, at + half)
        let rms = ((prefix[end] - prefix[start]) / Double(end - start)).squareRoot()
        let wanted = min(averageGain * 4, max(averageGain / 4, Double(level) / max(rms, 1e-6)))
        smoothed += (wanted - smoothed) * ease
        gains.append(smoothed)
        at += hop
    }
    return track.map { channel in
        var out = channel
        for index in 0..<frames {
            let position = Double(index) / Double(hop)
            let k = min(gains.count - 1, Int(position))
            let next = min(gains.count - 1, k + 1)
            let gain = gains[k] + (gains[next] - gains[k]) * (position - Double(k))
            out[index] = channel[index] * Float(gain)
        }
        return out
    }
}

/// A file's samples at the mix rate, one array per channel.
func decode(_ url: URL, channels: AVAudioChannelCount) throws -> [[Float]] {
    let file = try AVAudioFile(forReading: url)
    guard let raw = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
          let target = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels),
          let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
        throw VideoError("cannot decode \(url.lastPathComponent)")
    }
    try file.read(into: raw)
    let capacity = AVAudioFrameCount(Double(raw.frameLength) * sampleRate / file.processingFormat.sampleRate) + 4096
    guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
        throw VideoError("cannot buffer \(url.lastPathComponent)")
    }
    var supplied = false
    var conversionError: NSError?
    let status = converter.convert(to: converted, error: &conversionError) { _, outStatus in
        if supplied {
            outStatus.pointee = .endOfStream
            return nil
        }
        supplied = true
        outStatus.pointee = .haveData
        return raw
    }
    guard status != .error, converted.frameLength > 0, let data = converted.floatChannelData else {
        throw VideoError("converting \(url.lastPathComponent): \(conversionError?.localizedDescription ?? "no audio")")
    }
    let frames = Int(converted.frameLength)
    return (0..<Int(channels)).map { Array(UnsafeBufferPointer(start: data[$0], count: frames)) }
}

/// The video's sound, stereo at the mix rate: every clip where its cue
/// places it with the voice brought to `voicePeak`, and under it the bed
/// levelled to `bedLevel`, played from the track's start and around
/// again should the video outlast it, faded in and out at the ends.
/// Nothing beyond full scale.
func writeSoundtrack(cues: [Cue], music: URL?, to url: URL) throws {
    let total = Int((cues.reduce(0) { $0 + $1.duration } * sampleRate).rounded())
    var voice = [Float](repeating: 0, count: total)
    for cue in cues {
        let clip = try decode(cue.audio, channels: 1)[0]
        let start = Int(((cue.start + cue.speechStart) * sampleRate).rounded())
        for (offset, sample) in clip.enumerated() where start + offset < total {
            voice[start + offset] = sample
        }
    }
    let top = voice.reduce(0) { max($0, abs($1)) }
    if top > 0 {
        let gain = voicePeak / top
        voice = voice.map { $0 * gain }
    }
    var left = voice
    var right = voice
    if let music {
        let track = levelled(try decode(music, channels: 2), to: bedLevel)
        let frames = track[0].count
        let seconds = Double(total) / sampleRate
        for index in 0..<total {
            let time = Double(index) / sampleRate
            let envelope = Float(max(0, min(1, time / bedFadeIn, (seconds - time) / bedFadeOut)))
            left[index] += track[0][index % frames] * envelope
            right[index] += track[1][index % frames] * envelope
        }
    }
    guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total)),
          let data = buffer.floatChannelData else {
        throw VideoError("cannot buffer the soundtrack")
    }
    buffer.frameLength = AVAudioFrameCount(total)
    for index in 0..<total {
        data[0][index] = max(-1, min(1, left[index]))
        data[1][index] = max(-1, min(1, right[index]))
    }
    let out = try AVAudioFile(forWriting: url, settings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false,
    ], commonFormat: .pcmFormatFloat32, interleaved: false)
    try out.write(from: buffer)
}

// MARK: - Look

enum Look {
    static let width: CGFloat = 1920
    static let height: CGFloat = 1080
    static let bg = Color(red: 10 / 255, green: 13 / 255, blue: 18 / 255)
    static let text = Color(red: 238 / 255, green: 241 / 255, blue: 246 / 255)
    static let muted = Color(red: 152 / 255, green: 162 / 255, blue: 179 / 255)
    static let green = Color(red: 52 / 255, green: 199 / 255, blue: 89 / 255)
    static let teal = Color(red: 77 / 255, green: 208 / 255, blue: 165 / 255)
    static let orange = Color(red: 1, green: 149 / 255, blue: 0)
    static let red = Color(red: 1, green: 69 / 255, blue: 58 / 255)
    static let card = Color.white.opacity(0.045)
    static let hairline = Color.white.opacity(0.09)
}

func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
func easeOut(_ x: Double) -> Double { let t = clamp01(x); return 1 - pow(1 - t, 3) }
func easeInOut(_ x: Double) -> Double {
    let t = clamp01(x)
    return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
}
/// Eased 0 to 1 while `t` runs from `start` to `start + length`.
func ramp(_ t: Double, _ start: Double, _ length: Double) -> Double {
    easeOut((t - start) / length)
}
/// Piecewise keyframe interpolation with ease-in-out between keys.
func keyframes(_ t: Double, _ keys: [(Double, Double)]) -> Double {
    guard let firstKey = keys.first, let lastKey = keys.last else { return 0 }
    if t <= firstKey.0 { return firstKey.1 }
    if t >= lastKey.0 { return lastKey.1 }
    for i in 1..<keys.count where t <= keys[i].0 {
        let (t0, v0) = keys[i - 1], (t1, v1) = keys[i]
        return v0 + (v1 - v0) * easeInOut((t - t0) / (t1 - t0))
    }
    return lastKey.1
}

struct Reveal: ViewModifier {
    let progress: Double
    func body(content: Content) -> some View {
        content.opacity(progress).offset(y: (1 - progress) * 28)
    }
}

extension View {
    func reveal(_ progress: Double) -> some View { modifier(Reveal(progress: progress)) }
}

struct Backdrop: View {
    let time: Double
    var body: some View {
        ZStack {
            Look.bg
            RadialGradient(colors: [Look.green.opacity(0.17), .clear],
                           center: UnitPoint(x: 0.86 + 0.03 * sin(time / 9), y: 0.06 + 0.03 * cos(time / 7)),
                           startRadius: 0, endRadius: 860)
            RadialGradient(colors: [Look.teal.opacity(0.08), .clear],
                           center: UnitPoint(x: 0.08, y: 0.98), startRadius: 0, endRadius: 760)
        }
    }
}

/// The vertical battery from the site's logo.
struct BatteryGlyph: View {
    var level: Double = 0.62
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let capW = w * 0.4, capH = h * 0.075
            let body = CGRect(x: 0, y: capH, width: w, height: h - capH)
            let cap = CGRect(x: (w - capW) / 2, y: 0, width: capW, height: capH * 1.9)
            ctx.fill(Path(roundedRect: cap, cornerRadius: capH * 0.6), with: .color(.white.opacity(0.85)))
            ctx.fill(Path(roundedRect: body, cornerRadius: w * 0.17), with: .color(.white))
            let inner = body.insetBy(dx: w * 0.13, dy: w * 0.13)
            let fillH = inner.height * level
            let fill = CGRect(x: inner.minX, y: inner.maxY - fillH, width: inner.width, height: fillH)
            ctx.fill(Path(roundedRect: fill, cornerRadius: w * 0.08), with: .color(Look.green))
        }
    }
}

/// A wide horizontal battery, cap on the right, with a tinted fill.
struct WideBattery: View {
    let level: Double
    let tint: Color
    var body: some View {
        Canvas { ctx, size in
            let capW = size.width * 0.018
            let body = CGRect(x: 0, y: 0, width: size.width - capW - 8, height: size.height)
            let radius = size.height * 0.2
            ctx.stroke(Path(roundedRect: body.insetBy(dx: 3, dy: 3), cornerRadius: radius),
                       with: .color(.white.opacity(0.75)), lineWidth: 6)
            let cap = CGRect(x: body.maxX + 8, y: size.height * 0.3, width: capW, height: size.height * 0.4)
            ctx.fill(Path(roundedRect: cap, cornerRadius: capW * 0.4), with: .color(.white.opacity(0.75)))
            let inner = body.insetBy(dx: 14, dy: 14)
            let fill = CGRect(x: inner.minX, y: inner.minY, width: inner.width * level, height: inner.height)
            ctx.fill(Path(roundedRect: fill, cornerRadius: radius * 0.6), with: .color(tint))
        }
    }
}

/// The menu bar battery icon, drawn like AppDelegate.renderMenuBarIcon.
struct MenuBarBattery: View {
    let percentage: Double
    var body: some View {
        Canvas { ctx, size in
            let k = size.height / 18
            let battW = 24 * k, battH = 11 * k, capW = 2.8 * k
            let battY = (size.height - battH) / 2
            let body = CGRect(x: 0.5 * k, y: battY + 0.5 * k, width: battW - k, height: battH - k)
            ctx.stroke(Path(roundedRect: body, cornerRadius: 2 * k), with: .color(.white.opacity(0.7)), lineWidth: k)
            let cap = CGRect(x: battW, y: battY + battH * 0.3, width: capW, height: battH * 0.4)
            ctx.fill(Path(roundedRect: cap, cornerRadius: 0.8 * k), with: .color(.white.opacity(0.7)))
            let inset = 2 * k
            let fillMaxW = battW - k - inset * 2
            let fill = CGRect(x: 0.5 * k + inset, y: battY + 0.5 * k + inset,
                              width: fillMaxW * percentage / 100, height: battH - k - inset * 2)
            ctx.fill(Path(roundedRect: fill, cornerRadius: k), with: .color(.white))
        }
    }
}

/// A panel render placed on the dark backdrop, with the popover's rounded
/// corners, a hairline, a drop shadow, and an optional highlighted region
/// (normalized coordinates within the panel image). `zoom` magnifies the
/// content inside the panel's own outline, like a camera move, so a zoomed
/// panel never spills over its neighbors.
struct Panel: View {
    let image: NSImage
    let width: CGFloat
    var highlight: CGRect? = nil
    var highlightAlpha: Double = 0
    var zoom: CGFloat = 1
    var anchor: UnitPoint = .center

    var body: some View {
        let height = width * image.size.height / image.size.width
        let outline = RoundedRectangle(cornerRadius: width / 580 * 12, style: .continuous)
        ZStack(alignment: .topLeading) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: width, height: height)
            if let highlight, highlightAlpha > 0.001 {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Look.green.opacity(0.12))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Look.green, lineWidth: 4))
                    .frame(width: highlight.width * width, height: highlight.height * height)
                    .offset(x: highlight.minX * width, y: highlight.minY * height)
                    .opacity(highlightAlpha)
            }
        }
        .frame(width: width, height: height)
        .scaleEffect(zoom, anchor: anchor)
        .frame(width: width, height: height)
        .clipShape(outline)
        .overlay(outline.stroke(Color.white.opacity(0.16), lineWidth: 1))
        .shadow(color: .black.opacity(0.55), radius: 30, y: 16)
    }
}

/// Regions of the panel renders that scenes call out, as fractions of the
/// image. Measured on the 0.0.65 layout (see make-video.sh for the export).
enum Regions {
    static let statGrid = CGRect(x: 0.02, y: 0.312, width: 0.96, height: 0.355)
    static let slider = CGRect(x: 0.02, y: 0.684, width: 0.96, height: 0.106)
    static let chargeToFullRow = CGRect(x: 0.02, y: 0.806, width: 0.96, height: 0.04)
    static let dischargeRow = CGRect(x: 0.02, y: 0.782, width: 0.96, height: 0.038)
    static let keepAwakeRow = CGRect(x: 0.02, y: 0.87, width: 0.96, height: 0.04)
}

struct Assets {
    let charging: NSImage
    let holding: NSImage
    let discharge: NSImage
    let full: NSImage
    let keepAwake: NSImage
    /// The music credit for the closing card, when the music asks for one.
    let musicCredit: String?

    init(panels: URL, musicCredit: String?) throws {
        self.musicCredit = musicCredit
        func load(_ name: String) throws -> NSImage {
            let url = panels.appendingPathComponent("\(name).png")
            guard let image = NSImage(contentsOf: url) else {
                throw VideoError("missing panel render \(url.path); run the exporter first")
            }
            return image
        }
        charging = try load("charging")
        holding = try load("holding")
        discharge = try load("discharge")
        full = try load("full")
        keepAwake = try load("keepawake")
    }
}

// MARK: - Shared pieces

struct Headline: View {
    let text: String
    var size: CGFloat = 64
    var alignment: TextAlignment = .center
    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .bold))
            .foregroundColor(Look.text)
            .lineLimit(2)
            .multilineTextAlignment(alignment)
    }
}

struct FeatureRow: View {
    let icon: String
    let title: String
    let detail: String
    let progress: Double
    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Look.green.opacity(0.16))
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(Look.green)
            }
            .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 32, weight: .semibold)).foregroundColor(Look.text)
                Text(detail).font(.system(size: 25)).foregroundColor(Look.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .reveal(progress)
    }
}

struct Card<Content: View>: View {
    let width: CGFloat
    let height: CGFloat?
    let content: Content
    init(width: CGFloat, height: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.width = width
        self.height = height
        self.content = content()
    }
    var body: some View {
        content
            .padding(36)
            .frame(width: width, height: height, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Look.card))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Look.hairline, lineWidth: 1))
    }
}

struct Logo: View {
    var size: CGFloat = 96
    var body: some View {
        HStack(spacing: size * 0.3) {
            BatteryGlyph().frame(width: size * 0.8, height: size * 1.18)
            Text("Ampere").font(.system(size: size, weight: .bold)).foregroundColor(Look.text)
        }
    }
}

/// 0 to 100 track with the green band and its two draggers, in the style
/// of the site's auto-charge widget.
struct Band: View {
    let lower: Double
    let upper: Double
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let trackH: CGFloat = 26
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10)).frame(height: trackH)
                Capsule().fill(Look.green.opacity(0.85))
                    .frame(width: w * (upper - lower) / 100, height: trackH)
                    .offset(x: w * lower / 100)
                ForEach([("\(Int(lower.rounded()))%", lower, Look.orange), ("\(Int(upper.rounded()))%", upper, Look.green)], id: \.0) { label, value, tint in
                    VStack(spacing: 6) {
                        Text(label).font(.system(size: 24, weight: .semibold, design: .rounded)).foregroundColor(tint)
                        Image(systemName: "arrowtriangle.down.fill").font(.system(size: 16)).foregroundColor(tint)
                    }
                    .frame(width: 100)
                    .position(x: w * value / 100, y: -34)
                }
                HStack {
                    ForEach([0, 25, 50, 75, 100], id: \.self) { tick in
                        Text("\(tick)%").font(.system(size: 18)).foregroundColor(Look.muted)
                        if tick < 100 { Spacer() }
                    }
                }
                .offset(y: trackH + 22)
            }
            .frame(height: trackH)
            .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - Scenes

struct TitleScene: View {
    let t: Double
    var body: some View {
        VStack(spacing: 34) {
            Logo(size: 110).reveal(ramp(t, 0.3, 1.0))
            Text("Take \(Text("charge").foregroundColor(Look.green)) of your battery.")
                .font(.system(size: 66, weight: .bold))
                .foregroundColor(Look.text)
                .reveal(ramp(t, 0.9, 1.0))
            Text("Smart battery management for Apple Silicon Macs")
                .font(.system(size: 32)).foregroundColor(Look.muted)
                .reveal(ramp(t, 1.4, 1.0))
        }
    }
}

struct ProblemScene: View {
    let t: Double
    let sp: Double
    var body: some View {
        let level = keyframes(sp, [(0, 1), (0.30, 1), (0.48, 0.05), (0.56, 0.05), (0.78, 1), (1, 1)])
        let drained = keyframes(sp, [(0.34, 0), (0.44, 1), (0.60, 1), (0.72, 0)])
        VStack(spacing: 60) {
            Headline(text: "Lithium-ion ages fastest at the extremes.", size: 66)
                .reveal(ramp(t, 0.3, 0.9))
            ZStack(alignment: .leading) {
                WideBattery(level: level, tint: Look.red.opacity(0.9))
                Text("\(Int((level * 100).rounded()))%")
                    .font(.system(size: 60, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(.white)
                    .padding(.leading, 44)
            }
            .frame(width: 1200, height: 170)
            .reveal(ramp(t, 0.8, 1.0))
            ZStack {
                Text("Parked at 100%").opacity(clamp01((0.5 - drained) * 2))
                Text("Drained near empty").opacity(clamp01((drained - 0.5) * 2))
            }
            .font(.system(size: 40, weight: .semibold)).foregroundColor(Look.red)
            .reveal(ramp(sp, 0.08, 0.3))
            Text("A MacBook that lives on the charger spends its life at the top.")
                .font(.system(size: 32)).foregroundColor(Look.muted)
                .reveal(ramp(sp, 0.62, 0.3))
        }
    }
}

struct BoundsScene: View {
    let t: Double
    let sp: Double
    let panel: NSImage
    var body: some View {
        let bandIn = ramp(t, 1.0, 1.4)
        HStack(alignment: .center, spacing: 90) {
            Panel(image: panel, width: 600, highlight: Regions.slider,
                  highlightAlpha: ramp(sp, 0.26, 0.2) * (1 - ramp(sp, 0.92, 0.08)))
                .reveal(ramp(t, 0.3, 1.0))
            VStack(alignment: .leading, spacing: 30) {
                Headline(text: "Pick a healthy range.", size: 62)
                    .reveal(ramp(t, 0.5, 0.9))
                Band(lower: 40 - 22 * (1 - bandIn), upper: 60 + 22 * (1 - bandIn))
                    .frame(width: 760, height: 130)
                    .padding(.top, 24)
                    .reveal(ramp(t, 0.9, 0.9))
                FeatureRow(icon: "arrow.down.to.line", title: "Below 40%",
                           detail: "Charging starts and runs to the top of the range.",
                           progress: ramp(sp, 0.44, 0.22))
                FeatureRow(icon: "pause.circle", title: "Between the bounds",
                           detail: "Holds. No charging until you ask, or you dip below.",
                           progress: ramp(sp, 0.63, 0.2))
                FeatureRow(icon: "arrow.up.to.line", title: "Above 60%",
                           detail: "Charging stays off, or drains back down to the bound.",
                           progress: ramp(sp, 0.78, 0.2))
            }
            .frame(width: 820, alignment: .leading)
        }
    }
}

struct TelemetryScene: View {
    let t: Double
    let d: Double
    let sp: Double
    let panel: NSImage
    private let readouts: [(String, String)] = [
        ("powerplug.fill", "Adapter load"), ("battery.100percent", "Battery load"),
        ("desktopcomputer", "System load"), ("bolt.fill", "Voltage"),
        ("waveform.path.ecg", "Current"), ("thermometer.medium", "Temperature"),
        ("arrow.triangle.2.circlepath", "Cycle count"), ("stethoscope", "Health"),
        ("calendar", "Battery age"),
    ]
    var body: some View {
        let zoom = 1 + 0.32 * easeInOut(t / d)
        HStack(alignment: .center, spacing: 70) {
            Panel(image: panel, width: 620, highlight: Regions.statGrid,
                  highlightAlpha: ramp(sp, 0.05, 0.2) * (1 - ramp(sp, 0.9, 0.1)),
                  zoom: zoom, anchor: UnitPoint(x: 0.5, y: 0.47))
                .reveal(ramp(t, 0.3, 1.0))
            VStack(alignment: .leading, spacing: 40) {
                Headline(text: "Everything your battery\nwants you to know.", size: 58, alignment: .leading)
                    .fixedSize()
                    .reveal(ramp(t, 0.5, 0.9))
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(280), spacing: 18, alignment: .leading), count: 3),
                          alignment: .leading, spacing: 18) {
                    ForEach(Array(readouts.enumerated()), id: \.offset) { index, item in
                        HStack(spacing: 14) {
                            Image(systemName: item.0).font(.system(size: 22, weight: .semibold))
                                .foregroundColor(Look.green).frame(width: 30)
                            Text(item.1).font(.system(size: 26, weight: .medium)).foregroundColor(Look.text)
                        }
                        .padding(.horizontal, 20).padding(.vertical, 16)
                        .frame(width: 280, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Look.card))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Look.hairline, lineWidth: 1))
                        .reveal(ramp(sp, 0.28 + Double(index) * 0.065, 0.16))
                    }
                }
                Text("A dozen readouts, always current.")
                    .font(.system(size: 30)).foregroundColor(Look.muted)
                    .reveal(ramp(sp, 0.9, 0.1))
            }
            .frame(width: 900, alignment: .leading)
        }
        .padding(.leading, 40)
    }
}

/// A charge-level trace drawn progressively inside a card.
struct Trace: Shape {
    let points: [CGPoint]   // x in 0...1, y in percent
    let minY: Double
    let maxY: Double
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for (i, p) in points.enumerated() {
            let x = rect.minX + rect.width * p.x
            let y = rect.maxY - rect.height * (p.y - minY) / (maxY - minY)
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }
}

struct MicrochargeScene: View {
    let t: Double
    let sp: Double
    private static let sawtooth: [CGPoint] = {
        var points: [CGPoint] = [CGPoint(x: 0, y: 100)]
        let teeth = 14
        for i in 0..<teeth {
            let x0 = Double(i) / Double(teeth), x1 = Double(i + 1) / Double(teeth)
            points.append(CGPoint(x: x0 + (x1 - x0) * 0.8, y: 94))
            points.append(CGPoint(x: x1, y: 100))
        }
        return points
    }()
    private static let fullPass: [CGPoint] = [
        CGPoint(x: 0, y: 60), CGPoint(x: 0.42, y: 40), CGPoint(x: 0.5, y: 60),
        CGPoint(x: 0.92, y: 40), CGPoint(x: 1, y: 60),
    ]
    var body: some View {
        VStack(spacing: 50) {
            Headline(text: "No fragmented top-ups.", size: 62).reveal(ramp(t, 0.3, 0.9))
            HStack(spacing: 44) {
                chart(title: "Plain charger", subtitle: "Micro-charges at the top, all day.",
                      points: Self.sawtooth, minY: 30, maxY: 102, tint: Look.red, band: nil,
                      progress: ramp(sp, 0.02, 0.5), appear: ramp(t, 0.6, 0.9))
                chart(title: "With Ampere", subtitle: "One full pass: lower bound to upper.",
                      points: Self.fullPass, minY: 30, maxY: 102, tint: Look.green, band: (40, 60),
                      progress: ramp(sp, 0.45, 0.5), appear: ramp(t, 0.9, 0.9))
            }
            HStack(spacing: 14) {
                Image(systemName: "arrow.clockwise.circle.fill").font(.system(size: 30)).foregroundColor(Look.green)
                Text("Even after a restart, charging between the bounds stays off until you ask.")
                    .font(.system(size: 30)).foregroundColor(Look.muted)
            }
            .reveal(ramp(sp, 0.36, 0.25))
        }
    }

    private func chart(title: String, subtitle: String, points: [CGPoint], minY: Double, maxY: Double,
                       tint: Color, band: (Double, Double)?, progress: Double, appear: Double) -> some View {
        Card(width: 800, height: 470) {
            VStack(alignment: .leading, spacing: 18) {
                Text(title).font(.system(size: 34, weight: .semibold)).foregroundColor(Look.text)
                GeometryReader { geo in
                    ZStack(alignment: .topLeading) {
                        if let band {
                            let top = geo.size.height * (1 - (band.1 - minY) / (maxY - minY))
                            let bottom = geo.size.height * (1 - (band.0 - minY) / (maxY - minY))
                            Rectangle().fill(Look.green.opacity(0.14))
                                .frame(height: bottom - top).offset(y: top)
                        }
                        ForEach([100, 60, 40], id: \.self) { level in
                            let y = geo.size.height * (1 - (Double(level) - minY) / (maxY - minY))
                            Rectangle().fill(Look.hairline).frame(height: 1).offset(y: y)
                            Text("\(level)%").font(.system(size: 18)).foregroundColor(Look.muted)
                                .offset(x: geo.size.width - 56, y: y - 26)
                        }
                        Trace(points: points, minY: minY, maxY: maxY)
                            .trim(from: 0, to: progress)
                            .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                            .padding(.trailing, 88)
                    }
                }
                .frame(height: 270)
                Text(subtitle).font(.system(size: 26)).foregroundColor(Look.muted)
            }
        }
        .reveal(appear)
    }
}

struct OnDemandScene: View {
    let t: Double
    let sp: Double
    let full: NSImage
    let discharge: NSImage
    var body: some View {
        let second = ramp(sp, 0.56, 0.08)
        ZStack {
            beat(panel: full, region: Regions.chargeToFullRow, icon: "battery.100percent.bolt",
                 title: "Charge to Full",
                 detail: "One tap to 100% for the days you need it all. Your bounds stay untouched, and normal management takes over again once the charge completes.",
                 progress: ramp(t, 0.3, 1.0), highlight: ramp(sp, 0.12, 0.2))
                .opacity(1 - second)
                .offset(x: -60 * second)
            beat(panel: discharge, region: Regions.dischargeRow, icon: "arrow.down.to.line.compact",
                 title: "Discharge to Upper Bound",
                 detail: "Sitting above your bound? Actively drain back down to it, even with the charger plugged in.",
                 progress: second, highlight: ramp(sp, 0.74, 0.2))
                .offset(x: 60 * (1 - second))
        }
    }

    private func beat(panel: NSImage, region: CGRect, icon: String, title: String, detail: String,
                      progress: Double, highlight: Double) -> some View {
        HStack(alignment: .center, spacing: 100) {
            Panel(image: panel, width: 600, highlight: region, highlightAlpha: highlight * progress)
                .reveal(progress)
            VStack(alignment: .leading, spacing: 26) {
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Look.green.opacity(0.16))
                    Image(systemName: icon).font(.system(size: 40, weight: .semibold)).foregroundColor(Look.green)
                }
                .frame(width: 92, height: 92)
                Text(title).font(.system(size: 56, weight: .bold)).foregroundColor(Look.text)
                Text(detail).font(.system(size: 30)).foregroundColor(Look.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 780, alignment: .leading)
            .reveal(progress)
        }
    }
}

struct SafetyScene: View {
    let t: Double
    let sp: Double
    var body: some View {
        VStack(spacing: 60) {
            Headline(text: "Safe by design. Reversible by default.", size: 62).reveal(ramp(t, 0.3, 0.9))
            HStack(alignment: .top, spacing: 40) {
                card(icon: "moon.zzz.fill", title: "Sleep-safe charging",
                     detail: "Close the lid mid-charge: the charge pauses just before sleep and continues when your Mac wakes. It never overshoots your bound.",
                     progress: ramp(sp, 0.02, 0.25))
                card(icon: "arrow.uturn.backward.circle.fill", title: "Quit means clean slate",
                     detail: "Quitting Ampere restores every system default: charging, sleep, everything.",
                     progress: ramp(sp, 0.47, 0.22))
                card(icon: "checkmark.shield.fill", title: "Crash-proof",
                     detail: "Force-killed? A watchdog puts your Mac back to normal within seconds.",
                     progress: ramp(sp, 0.66, 0.22))
            }
        }
    }

    private func card(icon: String, title: String, detail: String, progress: Double) -> some View {
        Card(width: 540, height: 420) {
            VStack(alignment: .leading, spacing: 24) {
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Look.green.opacity(0.16))
                    Image(systemName: icon).font(.system(size: 36, weight: .semibold)).foregroundColor(Look.green)
                }
                .frame(width: 84, height: 84)
                Text(title).font(.system(size: 36, weight: .bold)).foregroundColor(Look.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail).font(.system(size: 27)).foregroundColor(Look.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .reveal(progress)
    }
}

struct MenuBarMock: View {
    let hover: Double
    var body: some View {
        ZStack(alignment: .bottom) {
            HStack(spacing: 34) {
                Spacer()
                HStack(spacing: 10) {
                    MenuBarBattery(percentage: 54).frame(width: 56, height: 36)
                    Text("54%").font(.system(size: 28, weight: .medium)).foregroundColor(.white)
                }
                .padding(.horizontal, 16).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.16 * hover)))
                Image(systemName: "wifi").font(.system(size: 26, weight: .medium))
                Image(systemName: "magnifyingglass").font(.system(size: 26, weight: .medium))
                Image(systemName: "switch.2").font(.system(size: 26, weight: .medium))
                Text("Mon Sep 28  9:41 AM").font(.system(size: 28, weight: .medium))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 36)
            .frame(height: 64)
            .background(Color.white.opacity(0.08))
            Rectangle().fill(Look.hairline).frame(height: 1)
        }
    }
}

struct ExtrasScene: View {
    let t: Double
    let sp: Double
    let panel: NSImage
    var body: some View {
        let hover = ramp(t, 0.6, 0.6) * (1 - ramp(sp, 0.26, 0.1))
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                MenuBarMock(hover: hover)
                Text("54% — Charging — 14m to 60%")
                    .font(.system(size: 24)).foregroundColor(Color(white: 0.12))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.93)))
                    .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
                    .offset(x: -392, y: 74)
                    .opacity(hover)
            }
            .frame(height: 64)
            .reveal(ramp(t, 0.3, 0.8))
            Spacer()
            HStack(alignment: .center, spacing: 110) {
                VStack(alignment: .leading, spacing: 34) {
                    Headline(text: "Two clicks away,\nall the time.", size: 58, alignment: .leading)
                        .fixedSize()
                        .reveal(ramp(t, 0.5, 0.9))
                    FeatureRow(icon: "pin.fill", title: "Pin it, or float it",
                               detail: "Pin the panel open, or drag it off the menu bar to any spot on screen.",
                               progress: ramp(sp, 0.26, 0.22))
                    FeatureRow(icon: "cup.and.saucer.fill", title: "Keep Awake",
                               detail: "Hold off idle sleep for 15 minutes to 8 hours, or until you turn it off.",
                               progress: ramp(sp, 0.6, 0.18))
                    FeatureRow(icon: "arrow.right.circle.fill", title: "Launch at login",
                               detail: "Always there after a restart.",
                               progress: ramp(sp, 0.76, 0.14))
                    FeatureRow(icon: "arrow.down.circle.fill", title: "Verified in-app updates",
                               detail: "Downloads are checked against the Homebrew cask and Apple's signature.",
                               progress: ramp(sp, 0.87, 0.13))
                }
                .frame(width: 860, alignment: .leading)
                Panel(image: panel, width: 560, highlight: Regions.keepAwakeRow,
                      highlightAlpha: ramp(sp, 0.62, 0.15) * (1 - ramp(sp, 0.86, 0.08)))
                    .reveal(ramp(t, 0.8, 1.0))
            }
            Spacer()
        }
    }
}

struct InstallScene: View {
    let t: Double
    let sp: Double
    private let command = "brew install --cask az-code-lab/taps/ampere"
    var body: some View {
        let typed = Int((Double(command.count) * clamp01(sp / 0.24)).rounded())
        let caretOn = Int(t * 2.5) % 2 == 0
        VStack(spacing: 44) {
            Headline(text: "Up and running in a minute.", size: 62).reveal(ramp(t, 0.3, 0.9))
            HStack(spacing: 0) {
                Text("$ ").foregroundColor(Look.green)
                Text(String(command.prefix(typed))).foregroundColor(Look.text)
                Rectangle().fill(Look.text).frame(width: 18, height: 40)
                    .opacity(caretOn || typed < command.count ? 1 : 0)
                    .padding(.leading, 4)
                Spacer(minLength: 0)
            }
            .font(.system(size: 36, weight: .medium, design: .monospaced))
            .padding(.horizontal, 40).padding(.vertical, 30)
            .frame(width: 1180, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.black.opacity(0.45)))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Look.hairline, lineWidth: 1))
            .reveal(ramp(t, 0.6, 0.9))
            Text("or download Ampere.dmg from amperebattery.app and drag it to Applications")
                .font(.system(size: 28)).foregroundColor(Look.muted)
                .reveal(ramp(sp, 0.2, 0.2))
            HStack(spacing: 32) {
                step(number: "1", title: "Install", detail: "Homebrew or the disk image, signed and notarized.", progress: ramp(sp, 0.3, 0.2))
                step(number: "2", title: "Grant admin once", detail: "One password prompt installs the charge-control helper.", progress: ramp(sp, 0.42, 0.2))
                step(number: "3", title: "Set your bounds", detail: "Turn on auto charge, pick a range, forget about it.", progress: ramp(sp, 0.52, 0.2))
            }
            HStack(spacing: 18) {
                Text("Free in the default 40 to 60% range").foregroundColor(Look.text)
                Text("·").foregroundColor(Look.muted)
                Text("One-time license unlocks custom bounds").foregroundColor(Look.green)
            }
            .font(.system(size: 30, weight: .medium))
            .reveal(ramp(sp, 0.7, 0.25))
        }
    }

    private func step(number: String, title: String, detail: String, progress: Double) -> some View {
        Card(width: 372, height: 250) {
            VStack(alignment: .leading, spacing: 16) {
                Text(number).font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundColor(Color(red: 4 / 255, green: 23 / 255, blue: 10 / 255))
                    .frame(width: 52, height: 52).background(Circle().fill(Look.green))
                Text(title).font(.system(size: 32, weight: .semibold)).foregroundColor(Look.text)
                Text(detail).font(.system(size: 24)).foregroundColor(Look.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .reveal(progress)
    }
}

struct OutroScene: View {
    let t: Double
    let credit: String?
    var body: some View {
        ZStack {
            VStack(spacing: 30) {
                Logo(size: 120).reveal(ramp(t, 0.2, 1.0))
                Text("amperebattery.app")
                    .font(.system(size: 60, weight: .semibold, design: .rounded)).foregroundColor(Look.green)
                    .reveal(ramp(t, 0.8, 1.0))
                Text("Take charge of your battery.")
                    .font(.system(size: 34)).foregroundColor(Look.muted)
                    .reveal(ramp(t, 1.2, 1.0))
            }
            if let credit {
                VStack {
                    Spacer()
                    Text(credit)
                        .font(.system(size: 24)).foregroundColor(Look.muted.opacity(0.8))
                        .padding(.bottom, 54)
                        .reveal(ramp(t, 1.6, 1.0))
                }
            }
        }
        .frame(width: Look.width, height: Look.height)
    }
}

// MARK: - Frame

struct Frame: View {
    let cue: Cue
    let t: Double
    let global: Double
    let assets: Assets

    var body: some View {
        let fade = min(1, t / 0.55) * min(1, (cue.duration - t) / 0.55)
        ZStack {
            Backdrop(time: global)
            content
                .opacity(clamp01(fade))
                .frame(width: Look.width, height: Look.height)
        }
        .frame(width: Look.width, height: Look.height)
        .clipped()
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var content: some View {
        let sp = cue.speech(t)
        switch cue.scene.kind {
        case .title: TitleScene(t: t)
        case .problem: ProblemScene(t: t, sp: sp)
        case .bounds: BoundsScene(t: t, sp: sp, panel: assets.charging)
        case .telemetry: TelemetryScene(t: t, d: cue.duration, sp: sp, panel: assets.charging)
        case .microcharge: MicrochargeScene(t: t, sp: sp)
        case .onDemand: OnDemandScene(t: t, sp: sp, full: assets.full, discharge: assets.discharge)
        case .safety: SafetyScene(t: t, sp: sp)
        case .extras: ExtrasScene(t: t, sp: sp, panel: assets.keepAwake)
        case .install: InstallScene(t: t, sp: sp)
        case .outro: OutroScene(t: t, credit: assets.musicCredit)
        }
    }
}

@MainActor
final class FrameRenderer {
    private let renderer: ImageRenderer<Frame>
    private let assets: Assets

    init(assets: Assets, first: Cue) {
        self.assets = assets
        renderer = ImageRenderer(content: Frame(cue: first, t: 0, global: 0, assets: assets))
        renderer.scale = 1
        renderer.isOpaque = true
        renderer.proposedSize = ProposedViewSize(width: Look.width, height: Look.height)
    }

    /// Pixels per point of the frames: 1 for 1080p, 2 for 4K. The scenes
    /// are laid out in points, so every size draws the same picture.
    var scale: CGFloat {
        get { renderer.scale }
        set { renderer.scale = newValue }
    }

    func render(cue: Cue, t: Double) throws -> CGImage {
        renderer.content = Frame(cue: cue, t: t, global: cue.start + t, assets: assets)
        guard let image = renderer.cgImage else { throw VideoError("frame render failed at \(cue.start + t)s") }
        return image
    }
}

// MARK: - Encoding

func draw(_ image: CGImage, into buffer: CVPixelBuffer) throws {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
    guard let context = CGContext(
        data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
    ) else { throw VideoError("pixel buffer context failed") }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else { throw VideoError("PNG encode failed") }
    try data.write(to: url)
}

// MARK: - Poster and captions (for the site)

/// The poster the site shows before play: the charge-bounds scene with
/// its rows revealing, which shows the product itself rather than the
/// title card, whose headline the hero above the player already says.
@MainActor
func writePoster(cues: [Cue], renderer: FrameRenderer, to url: URL) throws {
    guard let cue = cues.first(where: { $0.scene.kind == .bounds }) else {
        throw VideoError("no charge-bounds scene to take the poster from")
    }
    renderer.scale = 1
    let image = try renderer.render(cue: cue, t: cue.speechStart + 0.6 * cue.speechDuration)
    let rep = NSBitmapImageRep(cgImage: image)
    guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
        throw VideoError("JPEG encode failed")
    }
    try jpeg.write(to: url)
}

/// Spellings the narration uses so the voice says them right, and what
/// the captions show instead.
let captionSpellings = [
    "ampere battery dot app": "amperebattery.app",
    "forty to sixty percent": "40 to 60 percent",
    "one hundred percent": "100 percent",
]

/// The text cut where a sentence ends: after a full stop, question mark,
/// or exclamation mark that a space follows.
func sentences(_ text: String) -> [String] {
    var result: [String] = []
    var current = ""
    let characters = Array(text)
    for (index, character) in characters.enumerated() {
        current.append(character)
        if ".?!".contains(character), index + 1 < characters.count, characters[index + 1] == " " {
            result.append(current.trimmingCharacters(in: .whitespaces))
            current = ""
        }
    }
    let rest = current.trimmingCharacters(in: .whitespaces)
    if !rest.isEmpty { result.append(rest) }
    return result
}

/// English captions (WebVTT) for the narration: one cue per sentence,
/// each given its share of its clip's time by length.
func writeCaptions(cues: [Cue], to url: URL) throws {
    func stamp(_ seconds: Double) -> String {
        let whole = Int(seconds)
        return String(format: "%02d:%02d:%02d.%03d", whole / 3600, whole / 60 % 60, whole % 60,
                      Int(((seconds - Double(whole)) * 1000).rounded()))
    }
    var text = "WEBVTT\n\n"
    var number = 0
    for cue in cues {
        var narration = cue.scene.narration
        for (spoken, shown) in captionSpellings {
            narration = narration.replacingOccurrences(of: spoken, with: shown)
        }
        let parts = sentences(narration)
        let total = Double(parts.reduce(0) { $0 + $1.count })
        var at = cue.start + cue.speechStart
        for part in parts {
            let length = cue.speechDuration * Double(part.count) / total
            number += 1
            text += "\(number)\n\(stamp(at)) --> \(stamp(at + length))\n\(part)\n\n"
            at += length
        }
    }
    try text.write(to: url, atomically: true, encoding: .utf8)
}

/// The video at `scale` pixels per point: 1 is 1080p, 2 is 4K.
@MainActor
func encode(cues: [Cue], narration: URL, renderer: FrameRenderer, scale: Int, to output: URL) async throws {
    try? FileManager.default.removeItem(at: output)
    let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
    writer.shouldOptimizeForNetworkUse = true

    renderer.scale = CGFloat(scale)
    let width = Int(Look.width) * scale
    let height = Int(Look.height) * scale
    // 10 Mb/s at 1080p; 28 Mb/s at 4K, ample for text and flat colour.
    let bitrate = scale == 1 ? 10_000_000 : 28_000_000
    let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoMaxKeyFrameIntervalKey: Int(fps) * 2,
            AVVideoExpectedSourceFrameRateKey: Int(fps),
        ],
        AVVideoColorPropertiesKey: [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ],
    ])
    video.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
    ])
    writer.add(video)

    let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 160_000,
    ])
    audio.expectsMediaDataInRealTime = false
    writer.add(audio)

    let asset = AVURLAsset(url: narration)
    guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
        throw VideoError("narration track missing")
    }
    let reader = try AVAssetReader(asset: asset)
    let audioOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    reader.add(audioOutput)

    guard writer.startWriting() else { throw writer.error ?? VideoError("writer failed to start") }
    guard reader.startReading() else { throw reader.error ?? VideoError("reader failed to start") }
    writer.startSession(atSourceTime: .zero)

    let total = cues.reduce(0) { $0 + Int(($1.duration * Double(fps)).rounded()) }
    var frame = 0
    var cueIndex = 0
    var localFrame = 0
    var videoDone = false
    var audioDone = false
    let started = Date()
    // Serve whichever input the writer is ready for. The writer interleaves
    // the tracks by holding one input back until the other catches up, so
    // blocking on a single input's readiness can deadlock; neither side
    // ever waits on the other here.
    while !(videoDone && audioDone) {
        guard writer.status == .writing else { throw writer.error ?? VideoError("writer stopped") }
        var progressed = false
        if !videoDone, video.isReadyForMoreMediaData {
            if cueIndex < cues.count {
                let cue = cues[cueIndex]
                let image = try renderer.render(cue: cue, t: Double(localFrame) / Double(fps))
                guard let pool = adaptor.pixelBufferPool else { throw VideoError("no pixel buffer pool") }
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                guard let buffer else { throw VideoError("pixel buffer allocation failed") }
                try draw(image, into: buffer)
                let pts = CMTime(value: CMTimeValue(frame), timescale: fps)
                guard adaptor.append(buffer, withPresentationTime: pts) else {
                    throw writer.error ?? VideoError("video append failed")
                }
                frame += 1
                localFrame += 1
                if localFrame >= Int((cue.duration * Double(fps)).rounded()) {
                    cueIndex += 1
                    localFrame = 0
                }
                if frame % (Int(fps) * 10) == 0 || frame == total {
                    let elapsed = Date().timeIntervalSince(started)
                    print(String(format: "  %3d%%  frame %d/%d  %.0fs elapsed", frame * 100 / total, frame, total, elapsed))
                }
            } else {
                video.markAsFinished()
                videoDone = true
            }
            progressed = true
        }
        if !audioDone, audio.isReadyForMoreMediaData {
            if let sample = audioOutput.copyNextSampleBuffer() {
                guard audio.append(sample) else { throw writer.error ?? VideoError("audio append failed") }
            } else {
                guard reader.status == .completed else { throw reader.error ?? VideoError("narration read failed") }
                audio.markAsFinished()
                audioDone = true
            }
            progressed = true
        }
        if !progressed { usleep(1000) }
    }
    await writer.finishWriting()
    guard writer.status == .completed else { throw writer.error ?? VideoError("writer did not complete") }
}

// MARK: - Main

@main
struct IntroVideo {
    @MainActor
    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write("IntroVideo: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }

    @MainActor
    static func run() async throws {
        // Progress lines should reach a log file as they happen.
        setvbuf(stdout, nil, _IOLBF, 0)
        var options: [String: String] = [:]
        var flags: Set<String> = []
        var arguments = CommandLine.arguments.dropFirst()
        while let argument = arguments.popFirst() {
            if argument == "--stills" { flags.insert(argument); continue }
            guard argument.hasPrefix("--"), let value = arguments.popFirst() else {
                throw VideoError("unexpected argument \(argument)")
            }
            options[argument] = value
        }
        guard let panels = options["--panels"], let work = options["--work"], let out = options["--out"] else {
            throw VideoError("usage: IntroVideo --panels DIR --work DIR --out FILE [--out-4k FILE] [--voice NAME] [--rate WPM] [--music FILE|none] [--music-dir DIR] [--stills]")
        }
        let voice = options["--voice"] ?? systemVoice
        let rate = options["--rate"].flatMap(Int.init)
        let workURL = URL(fileURLWithPath: work, isDirectory: true)
        try FileManager.default.createDirectory(at: workURL, withIntermediateDirectories: true)

        print("Narration: \(voice == systemVoice ? "system voice (Accessibility > Read & Speak)" : voice)")
        let cues = try buildTimeline(work: workURL, voice: voice, rate: rate)
        for cue in cues {
            print(String(format: "  %-11@ %5.1fs  (speech %.1fs)", "\(cue.scene.kind)", cue.duration, cue.speechDuration))
        }
        let runtime = cues.reduce(0) { $0 + $1.duration }
        print(String(format: "Runtime: %.1fs", runtime))

        let soundtrack = try await Soundtrack.resolve(options)
        if let music = soundtrack.music {
            print("Music: \(soundtrack.track.map { "\($0.title) by \($0.artist), \($0.license)" } ?? music.path)")
        } else {
            print("Music: none")
        }
        let assets = try Assets(panels: URL(fileURLWithPath: panels, isDirectory: true), musicCredit: soundtrack.credit)
        let renderer = FrameRenderer(assets: assets, first: cues[0])

        if flags.contains("--stills") {
            let stills = workURL.appendingPathComponent("stills", isDirectory: true)
            try FileManager.default.createDirectory(at: stills, withIntermediateDirectories: true)
            for (index, cue) in cues.enumerated() {
                for (k, fraction) in [0.3, 0.6, 0.92].enumerated() {
                    let image = try renderer.render(cue: cue, t: cue.duration * fraction)
                    try writePNG(image, to: stills.appendingPathComponent(String(format: "%02d-%@-%d.png", index, "\(cue.scene.kind)", k)))
                }
            }
            print("Stills written to \(stills.path)")
            return
        }

        let sound = workURL.appendingPathComponent("soundtrack.caf")
        try writeSoundtrack(cues: cues, music: soundtrack.music, to: sound)
        // Encode in the scratch directory and move the finished file into
        // place: the writer's fast-start pass can leave a "<name>.sb-…"
        // sibling behind, which then stays in scratch rather than beside
        // the deliverable.
        let rendered = workURL.appendingPathComponent("render.mp4")
        print("Encoding \(out) (1920x1080)")
        try await encode(cues: cues, narration: sound, renderer: renderer, scale: 1, to: rendered)
        let destination = URL(fileURLWithPath: out)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: rendered, to: destination)
        print("Done: \(out)")
        // Beside the 1080p video, what the site's player needs: a poster
        // and captions, named after it (Ampere-Intro.jpg, Ampere-Intro.en.vtt).
        let base = destination.deletingPathExtension()
        let poster = base.appendingPathExtension("jpg")
        try writePoster(cues: cues, renderer: renderer, to: poster)
        let captions = URL(fileURLWithPath: base.path + ".en.vtt")
        try writeCaptions(cues: cues, to: captions)
        print("Poster: \(poster.path)\nCaptions: \(captions.path)")
        if let out4K = options["--out-4k"] {
            let rendered4K = workURL.appendingPathComponent("render-4k.mp4")
            print("Encoding \(out4K) (3840x2160)")
            try await encode(cues: cues, narration: sound, renderer: renderer, scale: 2, to: rendered4K)
            let destination4K = URL(fileURLWithPath: out4K)
            try? FileManager.default.removeItem(at: destination4K)
            try FileManager.default.moveItem(at: rendered4K, to: destination4K)
            print("Done: \(out4K)")
        }
    }
}
