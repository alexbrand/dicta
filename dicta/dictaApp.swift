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
import Carbon.HIToolbox // for kVK_ANSI_V
import ApplicationServices
import os.log
import UserNotifications

extension Logger {
    static let transcriber = Logger(subsystem: "com.your.bundleid", category: "Transcriber")
}

@main
struct PushToTranscribeApp: App {
    @StateObject private var transcriber = Transcriber()
    @State private var axTrusted = AXPerms.isTrusted

    var body: some Scene {
        MenuBarExtra("PushToTranscribe", systemImage: "mic") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(transcriber.statusText, systemImage: transcriber.menuIcon)
                        .font(.headline)
                    Spacer()
                    if !axTrusted {
                        Button("Enable Accessibility…") {
                            let nowTrusted = AXPerms.requestPromptOnce()
                            if !nowTrusted { AXPerms.openSettings() }
                            Task {
                                let trusted = await AXPerms.pollUntilTrusted()
                                await MainActor.run {
                                    axTrusted = trusted
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

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
                KeyboardShortcuts.Recorder("Push-to-Talk Shortcut:", name: .pushToTalk)
                Toggle("Play start/stop sounds", isOn: $transcriber.playEarcons)
                Toggle("Restore clipboard after paste", isOn: $transcriber.restoreClipboard)

                Divider()
                Button(transcriber.isRecording ? "Stop Recording" : "Start Recording") {
                    if transcriber.isRecording {
                        Task { await transcriber.stopPTT() }
                    } else {
                        if AXPerms.isTrusted {
                            Task { await transcriber.startPTT() }
                        } else {
                            let nowTrusted = AXPerms.requestPromptOnce()
                            if !nowTrusted { AXPerms.openSettings() }
                            Task {
                                let trusted = await AXPerms.pollUntilTrusted()
                                await MainActor.run {
                                    axTrusted = trusted
                                }
                            }
                        }
                    }
                }
                .keyboardShortcut(.space, modifiers: [])
                
                Button("Quit") { NSApp.terminate(nil) }
            }
            .padding(12)
            .frame(width: 340)
            .onAppear {
                axTrusted = AXPerms.isTrusted
                if !axTrusted {
                    Task {
                        _ = AXPerms.requestPromptOnce()
                        let trusted = await AXPerms.pollUntilTrusted()
                        await MainActor.run {
                            axTrusted = trusted
                        }
                    }
                }
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            VStack(alignment: .leading, spacing: 12) {
                Text("Push-to-Transcribe").font(.title2).bold()
                Text("Hold the shortcut to record. Release to insert the transcript where your cursor is.")
                    .foregroundStyle(.secondary)
                KeyboardShortcuts.Recorder("Push-to-Talk Shortcut:", name: .pushToTalk)
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
enum RecordingState {
    case idle           // Ready to record
    case recording      // Currently recording
    case transcribing   // Processing the audio
    case loadingModel   // Setting up Whisper
    case error(String)  // Something went wrong
}

@MainActor
final class Transcriber: ObservableObject {
    @Published private(set) var state: RecordingState = .idle

    @Published var lastTranscript: String? = nil
    @Published var playEarcons = true
    @Published var restoreClipboard = true

    private var recorder: AVAudioRecorder?
    private var tempFileURL: URL?

    private var whisper: WhisperKit? // Keep the pipeline warm between runs

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }
        
    var statusText: String {
        switch state {
        case .idle: return "Ready"
        case .recording: return "Listening... (hold to speak)"
        case .transcribing: return "Transcribing..."
        case .loadingModel: return "Loading Whisper model..."
        case .error(let message): return "Error: \(message)"
        }
    }
    
    private func setState(_ newState: RecordingState) {
        state = newState
    }

    var menuIcon: String {
        switch state {
            case .loadingModel: return "arrow.down.circle"
            case .recording: return "waveform"
            case .transcribing: return "brain"
            default: return "mic"
        }
    }

    init() {
        // Register push-to-talk handlers once when Transcriber is created
        KeyboardShortcuts.onKeyDown(for: .pushToTalk) { [weak self] in
            Task { await self?.startPTT() }
        }
        KeyboardShortcuts.onKeyUp(for: .pushToTalk) { [weak self] in
            Task { await self?.stopPTT() }
        }
        
        // Initialize Whisper model at startup
        Task(priority: .userInitiated) { await loadWhisperModel() }
    }
    
    private func loadWhisperModel() async {
        setState(.loadingModel)
        defer { setState(.idle) }
        
        do {
            whisper = try await WhisperKit(prewarm: true, load: true)
        } catch {
            // Log the error but don't crash the app
            Logger.transcriber.debug("Failed to load Whisper model: \(error.localizedDescription)")
        }
    }

    func startPTT() async {
        guard case .idle = state else {
            notify("Busy transcribing. Try again in a moment.")
            return
        }
        
        do {
            try await checkMicrophonePermission()
        } catch {
            notify("Microphone access denied. Enable it in System Settings → Privacy & Security → Microphone.")
            NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            return
        }
        
        setState(.recording)

        do {
            tempFileURL = try makeTempAudioURL()
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            recorder = try AVAudioRecorder(url: tempFileURL!, settings: settings)
            recorder?.isMeteringEnabled = false
            recorder?.record()
            if playEarcons { NSSound.start.play() }
        } catch {
            notify("Failed to start recording: \(error.localizedDescription)")
        }
    }

    func stopPTT() async {
        guard isRecording else { return }
        defer { setState(.idle) }
        recorder?.stop()
        recorder = nil
        if playEarcons { NSSound.stop.play() }

        guard let url = tempFileURL else { return }
        await transcribe(url: url)
    }
    
    private func checkMicrophonePermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            let granted = await AVCaptureDevice.requestMicrophoneAccess()
            guard granted else {
                throw NSError(domain: "MicrophoneError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Access denied"])
            }
        case .denied, .restricted:
            throw NSError(domain: "MicrophoneError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Access denied"])
        case .authorized:
            break
        @unknown default:
            break
        }
    }

    private func transcribe(url: URL) async {
        setState(.transcribing)
        defer {
            setState(.idle)
            try? FileManager.default.removeItem(at: url)
            tempFileURL = nil
        }
        do {
            // Whisper model should already be loaded at startup, but fallback if needed
            if whisper == nil {
                whisper = try await WhisperKit(prewarm: true, load: true)
            }
            let text = try await whisper?.transcribe(audioPath: url.path)?.text ?? ""
            lastTranscript = text
            Logger.transcriber.debug("transcribed to: \(text)")
            await insertIntoFrontApp(text)
        } catch {
            let nserr = error as NSError
            if nserr.domain == NSURLErrorDomain && nserr.code == -1003 {
                notify("Network blocked or DNS failed. If this is a sandboxed build, enable App Sandbox → Outgoing Connections (Client). Then rebuild.")
            } else {
                notify("Transcription failed: \(error.localizedDescription)")
            }
        }
    }

    private func insertIntoFrontApp(_ text: String) async {
        guard !text.isEmpty else { return }
        
        let pb = NSPasteboard.general
        var originalItemsSnapshot: [NSPasteboardItem] = []

        if restoreClipboard {
            if let originalItems = pb.pasteboardItems {
                for item in originalItems {
                    let newItem = NSPasteboardItem()
                    // Copy all the data types from the original item to our new snapshot item.
                    for type in item.types {
                        if let data = item.data(forType: type) {
                            newItem.setData(data, forType: type)
                        }
                    }
                    originalItemsSnapshot.append(newItem)
                }
            }
        }

        // Now, we can safely modify the pasteboard because we have our own copy
        // of the original data, completely disconnected from the pasteboard system.
        pb.clearContents()
        pb.setString(text, forType: .string)

        // Wait for the previous app to regain focus
        try? await Task.sleep(for: .milliseconds(100))
        
        do {
            try synthesizeCommandV()
        } catch {
            Logger.transcriber.error("synthesizeCommandV failed: \(String(describing: error))")
        }

        // Restore the clipboard using our snapshot
        if restoreClipboard {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                // Safety check: only restore if the user hasn't copied something else
                if pb.string(forType: .string) == text {
                    pb.clearContents()
                    // This is now safe because originalItemsSnapshot contains new items
                    pb.writeObjects(originalItemsSnapshot)
                }
            }
        }
    }

    enum KeystrokeError: LocalizedError {
        case accessibilityNotTrusted
        case eventSourceUnavailable
        case keyEventCreationFailed

        var errorDescription: String? {
            switch self {
            case .accessibilityNotTrusted:
                return "Accessibility permission is not granted. Enable your app in System Settings → Privacy & Security → Accessibility."
            case .eventSourceUnavailable:
                return "Failed to create a CGEventSource for HID system state."
            case .keyEventCreationFailed:
                return "Failed to create the key-down/up CGEvent."
            }
        }
    }
    
    /// Synthesizes ⌘V (Paste). Throws if preconditions fail.
    /// - Parameter promptForAXIfNeeded: If true, macOS will show the system prompt to grant Accessibility.
    func synthesizeCommandV(promptForAXIfNeeded: Bool = true) throws {
        // 1) Check Accessibility trust (TCC “Accessibility”). Without this, posting events is blocked.
        let opts: CFDictionary = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: promptForAXIfNeeded as CFBoolean
        ] as CFDictionary

        if !AXIsProcessTrustedWithOptions(opts) {
            throw KeystrokeError.accessibilityNotTrusted
        }

        // 2) Create an event source that looks like real HID input.
        guard let src = CGEventSource(stateID: .hidSystemState) else {
            throw KeystrokeError.eventSourceUnavailable
        }

        // 3) Build keyDown/keyUp for V (kVK_ANSI_V == 0x09).
        let vKey: CGKeyCode = CGKeyCode(kVK_ANSI_V)
        guard
            let keyDown = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true),
            let keyUp   = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        else {
            throw KeystrokeError.keyEventCreationFailed
        }

        // Apply Command modifier for ⌘V
        keyDown.flags = .maskCommand
        keyUp.flags   = .maskCommand

        // 4) Post the events. (No failure signal from API; preflight + throws above are your guard rails.)
        keyDown.post(tap: .cghidEventTap)
        // Small delay to help some apps reliably register the stroke.
        usleep(10_000) // 10 ms
        keyUp.post(tap: .cghidEventTap)
    }

    private func makeTempAudioURL() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let file = dir.appendingPathComponent("ptt-\(UUID().uuidString).wav")
        return file
    }

    private func notify(_ message: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let mutable = UNMutableNotificationContent()
            mutable.title = "Push-to-Transcribe"
            mutable.body = message
            let req = UNNotificationRequest(identifier: UUID().uuidString, content: mutable, trigger: nil)
            center.add(req, withCompletionHandler: nil)
        }
    }
}

// MARK: - Tiny earcons (optional)
extension NSSound {
    static let start: NSSound = .init(named: NSSound.Name("Pop"))!
    static let stop: NSSound = .init(named: NSSound.Name("Submarine"))!
}

extension AVCaptureDevice {
    static func requestMicrophoneAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}

import Cocoa
import ApplicationServices

enum AXPerms {
    /// Non-prompting read of current state.
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }


    /// Try to show the one-time system prompt.
    /// Returns true if already trusted; false if not trusted (prompt may or may not appear).
    @discardableResult
    static func requestPromptOnce() -> Bool {
        let opts: CFDictionary = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true as CFBoolean
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    
    static func pollUntilTrusted(timeout: TimeInterval = 120,
                               interval: TimeInterval = 0.8) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        
        while Date() < deadline {
            if isTrusted {
                return true
            }
            try? await Task.sleep(for: .milliseconds(Int(interval * 1000)))
        }
        
        return false
    }
}
