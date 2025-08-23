// PushToTranscribeApp.swift
// Minimal menu bar MVP: push-to-talk -> record mic -> WhisperKit transcribe -> paste into front app
// macOS 14+ (for WhisperKit, MenuBarExtra)
// Dependencies (SPM):
//  - WhisperKit: https://github.com/argmaxinc/WhisperKit
//  - KeyboardShortcuts: https://github.com/sindresorhus/KeyboardShortcuts

import SwiftUI
import AVFoundation
import AppKit
import KeyboardShortcuts
import WhisperKit

@main
struct PushToTranscribeApp: App {
    @StateObject private var transcriber = Transcriber()

    var body: some Scene {
        MenuBarExtra("PushToTranscribe", systemImage: transcriber.menuIcon) {
            VStack(alignment: .leading, spacing: 8) {
                Label(transcriber.statusText, systemImage: transcriber.menuIcon)
                    .font(.headline)
                if let last = transcriber.lastTranscript, !last.isEmpty {
                    Text(last)
                        .font(.body)
                        .lineLimit(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .background(Color(NSColor.textBackgroundColor))
                        .cornerRadius(8)
                }
                Divider()
                KeyboardShortcuts.Recorder("Push‑to‑Talk Shortcut:", name: .pushToTalk)
                Toggle("Play start/stop sounds", isOn: $transcriber.playEarcons)
                Toggle("Restore clipboard after paste", isOn: $transcriber.restoreClipboard)
                Divider()
                Button(transcriber.isRecording ? "Stop Recording" : "Start Recording") {
                    if transcriber.isRecording {
                        Task { await transcriber.stopPTT() }
                    } else {
                        Task { await transcriber.startPTT() }
                    }
                }
                .keyboardShortcut(.space, modifiers: []) // enables Space while menu open
                Button("Quit") { NSApp.terminate(nil) }
            }
            .padding(12)
            .frame(width: 340)
        }
        .menuBarExtraStyle(.window)
        Settings {
            VStack(alignment: .leading, spacing: 12) {
                Text("Push‑to‑Transcribe")
                    .font(.title2).bold()
                Text("Hold the shortcut to record. Release to insert the transcript where your cursor is.")
                    .foregroundStyle(.secondary)
                KeyboardShortcuts.Recorder("Push‑to‑Talk Shortcut:", name: .pushToTalk)
                Toggle("Play start/stop sounds", isOn: $transcriber.playEarcons)
                Toggle("Restore clipboard after paste", isOn: $transcriber.restoreClipboard)
                Spacer()
            }
            .padding(20)
            .frame(width: 480)
        }
    }
}

extension KeyboardShortcuts.Name {
    // Default: ⌥⌘Space (you can change it in the menu)
    static let pushToTalk = Self("pushToTalk", default: .init(.space, modifiers: [.command, .option]))
}

// MARK: - Transcriber

@MainActor
final class Transcriber: ObservableObject {
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var lastTranscript: String? = nil
    @Published var playEarcons = true
    @Published var restoreClipboard = true

    private var recorder: AVAudioRecorder?
    private var tempFileURL: URL?

    private var whisper: WhisperKit? // Keep the pipeline warm between runs

    var statusText: String {
        if isRecording { return "Listening… (hold to speak)" }
        if isTranscribing { return "Transcribing…" }
        return "Idle"
    }

    var menuIcon: String {
        if isRecording { return "waveform" }
        if isTranscribing { return "brain" }
        return "mic"
    }

    init() {
        // Register push-to-talk handlers once when Transcriber is created
        KeyboardShortcuts.onKeyDown(for: .pushToTalk) { [weak self] in
            Task { await self?.startPTT() }
        }
        KeyboardShortcuts.onKeyUp(for: .pushToTalk) { [weak self] in
            Task { await self?.stopPTT() }
        }
    }

    func startPTT() async {
        guard !isRecording else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            let granted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
            }
            guard granted else { notify("Microphone access denied"); return }
        case .denied, .restricted:
            notify("Microphone access denied. Enable it in System Settings → Privacy & Security → Microphone.")
            return
        case .authorized: break
        @unknown default: break
        }

        do {
            tempFileURL = try makeTempAudioURL()
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            recorder = try AVAudioRecorder(url: tempFileURL!, settings: settings)
            recorder?.isMeteringEnabled = false
            recorder?.record()
            isRecording = true
            if playEarcons { NSSound.start.play() }
        } catch {
            notify("Failed to start recording: \(error.localizedDescription)")
        }
    }

    func stopPTT() async {
        guard isRecording else { return }
        recorder?.stop()
        isRecording = false
        if playEarcons { NSSound.stop.play() }

        guard let url = tempFileURL else { return }
        await transcribe(url: url)
    }

    private func transcribe(url: URL) async {
        isTranscribing = true
        defer { isTranscribing = false }
        do {
            if whisper == nil {
                // Initialize with default model (auto-downloads a suitable CoreML Whisper)
                whisper = try await WhisperKit()
            }
            let text = try await whisper?.transcribe(audioPath: url.path)?.text ?? ""
            lastTranscript = text
            print(text)
            await insertIntoFrontApp(text)
        } catch {
            let nserr = error as NSError
            if nserr.domain == NSURLErrorDomain && nserr.code == -1003 {
                notify("Network blocked or DNS failed. If this is a sandboxed build, enable App Sandbox → Outgoing Connections (Client). Then rebuild.")
            } else {
                notify("Transcription failed: \(error.localizedDescription)")
            }
        }
        // Cleanup temp file
        try? FileManager.default.removeItem(at: url)
        tempFileURL = nil
    }

    private func insertIntoFrontApp(_ text: String) async {
        guard !text.isEmpty else { return }

        let pb = NSPasteboard.general
        var snapshot: [NSPasteboardItem] = []
        if restoreClipboard {
            snapshot = pb.pasteboardItems ?? []
        }

        pb.clearContents()
        pb.setString(text, forType: .string)

        synthesizeCommandV()

        // Allow paste to happen, then restore clipboard
        if restoreClipboard {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                pb.clearContents()
                // Rebuild items (best-effort)
                for item in snapshot {
                    let newItem = NSPasteboardItem()
                    for type in item.types {
                        if let data = item.data(forType: type) {
                            newItem.setData(data, forType: type)
                        }
                    }
                    pb.writeObjects([newItem])
                }
            }
        }
    }

    private func synthesizeCommandV() {
        // Respect Secure Event Input: CGEventPost simply fails in secure fields
        guard let src = CGEventSource(stateID: .hidSystemState) else { return }
        let vKey: CGKeyCode = 0x09 // kVK_ANSI_V
        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        let keyUp = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
    }

    private func makeTempAudioURL() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let file = dir.appendingPathComponent("ptt-\(UUID().uuidString).m4a")
        return file
    }

    private func notify(_ message: String) {
        let note = NSUserNotification()
        note.title = "Push‑to‑Transcribe"
        note.informativeText = message
        NSUserNotificationCenter.default.deliver(note)
    }
}

// MARK: - Tiny earcons (optional)
extension NSSound {
    static let start: NSSound = .init(named: NSSound.Name("Pop"))!
    static let stop: NSSound = .init(named: NSSound.Name("Submarine"))!
}


// =============================
// Info.plist (drop into your Xcode app target)
// =============================
/*
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$(EXECUTABLE_NAME)</string>
    <key>CFBundleIdentifier</key>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>PushToTranscribe</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <!-- Run as agent: menu bar only, hide Dock icon -->
    <key>LSUIElement</key>
    <true/>
    <!-- Mic permission prompt text -->
    <key>NSMicrophoneUsageDescription</key>
    <string>Push‑to‑Transcribe needs access to your microphone to capture speech while you hold the shortcut.</string>
</dict>
</plist>
*/

// =============================
// PushToTranscribe.entitlements (macOS sandbox)
// =============================
/*
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.device.audio-input</key>
    <true/>
    <!-- Required for model download and HTTPS calls (WhisperKit → Hugging Face) -->
    <key>com.apple.security.network.client</key>
    <true/>
</dict>
</plist>
*/

// =============================
// README (setup notes)
// =============================
/*
# Push-to-Transcribe (Whisper) — Minimal MVP

## Requirements
- macOS 14+
- Xcode 15+

## Add dependencies (SPM)
1. In Xcode: File → Add Package Dependencies…
2. Add:
   - https://github.com/argmaxinc/WhisperKit (latest)
   - https://github.com/sindresorhus/KeyboardShortcuts (latest)

## App configuration
- Set Deployment Target to **macOS 14.0** or newer (WhisperKit requirement).
- Add the provided **Info.plist** contents (make sure `LSUIElement` is `true`).
- Add a macOS **Sandbox** and enable:
  - **Microphone** → `com.apple.security.device.audio-input`
  - **Outgoing Connections (Client)** → `com.apple.security.network.client`
- Build & Run. On first use, grant **Microphone** access. No Accessibility permission is needed for paste-based insertion.

## Usage
- Default hotkey is **⌥⌘Space**. Hold to record, release to paste the transcript where your cursor is.
- Change the shortcut from the menu bar popover or Settings.

## Notes
- This MVP transcribes *after* you release the key. WhisperKit will download a suitable model on first run.
- If you want live partials or AX insert, extend `Transcriber.insertIntoFrontApp` and add AX APIs.
*/


