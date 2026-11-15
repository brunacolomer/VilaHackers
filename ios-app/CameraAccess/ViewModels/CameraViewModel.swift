/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import AVFoundation
import MWDATCamera
import MWDATCore
import Observation
import SwiftUI
import simd
import UIKit
@preconcurrency import MediaPipeTasksVision

extension TimeInterval {
  /// Formats a duration as `mm:ss`.
  var formattedRecordingTime: String {
    let minutes = Int(self) / 60
    let seconds = Int(self) % 60
    return String(format: "%02d:%02d", minutes, seconds)
  }
}

/// A capture awaiting preview/share — a still photo or a recorded video file.
/// Drives a single `.sheet(item:)` so photo and video share one presentation.
enum CapturePreview: Identifiable {
  case photo(UIImage)
  case video(URL)

  var id: String {
    switch self {
    case .photo: return "photo"
    case .video(let url): return "video:\(url.absoluteString)"
    }
  }
}

/// Drives the camera screen by exercising the SDK's camera lifecycle as explicit
/// steps: create/start a `DeviceSession`, add and start a `Stream`, capture or
/// record, stop the stream, end the session. Owns the screen-scoped pieces —
/// active-device monitoring, the `DeviceSession`, and its `Stream`. The UI binds to
/// the SDK's own `DeviceSessionState` / `StreamState` so the sample shows the real
/// state machine.
@Observable
@MainActor
final class CameraViewModel {
  // MARK: - Device

  /// Whether an eligible device is currently active. Drives the "Put on your
  /// glasses" placeholder. Sourced from the auto device selector.
  private(set) var hasActiveDevice: Bool = false

  // MARK: - Session state (bound directly to the SDK)

  /// The device session's state, mirrored from `DeviceSession.statePublisher`.
  /// `.idle`/`.stopped` mean no live session.
  var sessionState: DeviceSessionState = .idle

  // MARK: - Preview

  /// The latest decoded preview frame. Read only by the isolated `LivePreviewView`
  /// so the ~24fps updates don't re-render the whole screen.
  var currentVideoFrame: UIImage?
  var hasReceivedFirstFrame: Bool = false
  /// Scenario recognised by Gemini from the glasses' video (every 2 s).
  var scene = SceneState()
  /// Whether a Gemini API key has been entered on this iPhone.
  var hasGeminiKey: Bool = GeminiSceneDetector.savedKey != nil
  /// Right-hand control state (shown as a pop-up while the hand is up).
  var levelGesture = LevelGestureState()
  /// Device chosen with the LEFT hand (= screen, = LED 2). Kept until changed.
  var selectedDevice: SmartDevice?
  /// TEMP debug: what the app sees for each hand (side, fingers, position).
  var handsDebug = "cap mà"
  /// Device Gemini sees the wearer looking at (updated every 2 s), nil = none.
  var lookedDevice: SmartDevice?
  /// Current level (0...1) of each device, as last sent to the Arduino.
  var deviceLevels: [SmartDevice: Float] = [.lamp1: 0, .lamp2: 0, .screen: 0.5]
  /// Last thing the room did on its own because the scenario changed (shown in the badge).
  var automationNote: String?
  /// IP of the Arduino UNO Q on the Wi-Fi. Saved between launches.
  var arduinoHost: String = ArduinoLink.savedHost
  /// Result of the last message sent to the Arduino (nil = OK / nothing sent).
  var arduinoError: String?
  var arduinoLastSentLevel: Int?

  /// The stream's state, mirrored from `Stream.statePublisher`. `.stopped` means
  /// no live stream.
  var streamState: StreamState = .stopped

  // MARK: - Capture preview

  /// The capture currently shown in the preview/share sheet (photo or video).
  var activePreview: CapturePreview?
  var isCapturingPhoto: Bool = false

  // MARK: - Video recording

  var isRecording: Bool = false
  /// Wall-clock start of the active recording (first written frame), mirrored from the
  /// recorder. Drives the isolated `RecordingTimerLabel`'s `TimelineView`, so the timer
  /// counts continuously — including through a stream pause. `nil` when not recording.
  var recordingStartDate: Date?
  /// Whether to record the glasses-microphone (Bluetooth HFP) audio into videos
  /// (sound-in-video). Toggled from the mic button shown while streaming.
  var includeAudioInStream: Bool = true
  /// Mic denied — iOS won't re-prompt. Drives the toggle's disabled look + tap-to-Settings.
  /// Still required for glasses audio: iOS gates HFP capture behind mic permission too.
  var micDenied: Bool { AVAudioApplication.shared.recordPermission == .denied }

  // MARK: - Errors

  /// Drives the single error alert. Uses the SDK's own `localizedDescription`
  /// rather than an app-maintained error map.
  var showError: Bool = false
  var errorMessage: String = ""

  /// Drives the confirm prompt shown before the camera-permission redirect to the
  /// Meta AI app — surfaced only when permission isn't already granted.
  var showCameraPermissionRedirectConfirm: Bool = false

  // MARK: - Derived session state

  var isSessionStarting: Bool { sessionState == .starting }
  var isSessionActive: Bool { sessionState == .started }
  /// A session exists and is connected (or connecting); a stream can be started.
  var hasSession: Bool {
    switch sessionState {
    case .starting, .started, .paused, .stopping: return true
    case .idle, .stopped: return false
    }
  }

  /// Human-readable session state for the status line.
  var sessionStateText: String { sessionState.description }

  // MARK: - Derived stream state

  var isStreaming: Bool { streamState == .streaming }
  /// A stream is attached (in any non-terminal state).
  var hasStream: Bool { streamState != .stopped }

  /// A session or stream start/stop is in flight. The UI shows a spinner and
  /// disables the controls until the SDK settles on a stable state, so transient
  /// states never need their own controls or labels.
  var isBusy: Bool {
    isSessionStarting || sessionState == .stopping
      || streamState == .starting || streamState == .waitingForDevice || streamState == .stopping
  }

  /// Human-readable stream state for the status line. `StreamState` has no
  /// `description`, so map it here.
  var streamStateText: String {
    switch streamState {
    case .streaming: return "streaming"
    case .starting: return "starting"
    case .waitingForDevice: return "waiting for device"
    case .stopping: return "stopping"
    case .stopped: return "stopped"
    case .paused: return "paused"
    }
  }

  /// The stream is paused (device-initiated, e.g. a single cap-touch tap). The
  /// last frame is retained, so the preview can stay on screen frozen.
  var isPaused: Bool { streamState == .paused }

  /// The preview surface (live frames, or the last held frame) should fill the
  /// screen: while streaming, while paused (frozen on the last frame), or while
  /// tearing down with a last frame so the stop loader overlays the preview.
  var showsLivePreview: Bool {
    isStreaming
      || ((streamState == .paused || streamState == .stopping) && currentVideoFrame != nil)
  }

  // MARK: - Private

  @ObservationIgnored private let wearables: WearablesInterface
  @ObservationIgnored private let deviceSelector: AutoDeviceSelector
  @ObservationIgnored private var deviceSession: DeviceSession?
  @ObservationIgnored private var camera: MWDATCamera.Camera?
  @ObservationIgnored private var isStoppingForBackground: Bool = false
  @ObservationIgnored private var backgroundStopSuppressionTask: Task<Void, Never>?

  @ObservationIgnored private let videoRecorder = VideoRecorder()
  // Decodes compressed hvc1 frames for on-screen preview. Not required for
  // recording — the passthrough writer handles compressed frames directly.
  @ObservationIgnored private let videoFrameDecoder = VideoFrameDecoder()
  // Sends a frame to Gemini every 2 s and keeps the current scenario.
  @ObservationIgnored private let sceneDetector = GeminiSceneDetector()
  // MediaPipe hand landmarks on every frame it can keep up with (drops the rest).
  @ObservationIgnored private let handTracker = HandTracker()
  // Left hand picks the lamp (1 or 2 fingers). Right hand: open hand held = brighter,
  // fist held = dimmer (one step every `holdSeconds`). Clap = both lamps off.
  @ObservationIgnored private var selectorFingers = FingerCountGesture()
  @ObservationIgnored private var holdDirection = 0  // +1 open hand, -1 fist, 0 none
  @ObservationIgnored private var holdSince = Date()
  @ObservationIgnored private var clapFrames = 0
  @ObservationIgnored private var lastClap = Date.distantPast
  private let holdSeconds: TimeInterval = 2
  private let holdStep: Float = 0.2  // 20 % per step
  @ObservationIgnored private let arduino = ArduinoLink()
  /// Gemini answers in a row that did NOT see the Arduino. Only after
  /// `arduinoMissesToForget` of them is it considered gone (~6 s at one frame / 2 s),
  /// so one blurry frame or a hand covering the board doesn't make it "disappear".
  @ObservationIgnored private var arduinoMisses = 0
  private let arduinoMissesToForget = 3
  /// What the eye on the Arduino's LED matrix currently shows (open = armed).
  @ObservationIgnored private var eyeOpen = false

  @ObservationIgnored private var deviceMonitorTask: Task<Void, Never>?
  @ObservationIgnored private var appLifecycleTask: Task<Void, Never>?
  @ObservationIgnored private let sessionTokenBag = ListenerTokenBag()
  @ObservationIgnored private let streamTokenBag = ListenerTokenBag()

  @ObservationIgnored private let photoCaptureFailureMessage =
    "Couldn't capture photo. There may not be enough storage, or another capture is in progress. Try again in a few moments."
  @ObservationIgnored private let backgroundStopErrorSuppressionTimeout: Duration

  // MARK: - Init

  init(
    wearables: WearablesInterface,
    backgroundStopErrorSuppressionTimeout: Duration = .seconds(5)
  ) {
    self.wearables = wearables
    self.deviceSelector = AutoDeviceSelector(wearables: wearables)
    self.backgroundStopErrorSuppressionTimeout = backgroundStopErrorSuppressionTimeout
    startDeviceMonitoring()
    startAppLifecycleMonitoring()
  }

  isolated deinit {
    deviceMonitorTask?.cancel()
    appLifecycleTask?.cancel()
    backgroundStopSuppressionTask?.cancel()
    deviceSession?.stop()
  }

  /// Saves the Gemini API key entered in the app (tap the scenario badge).
  func setGeminiKey(_ key: String) {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    sceneDetector.setKey(trimmed)
    hasGeminiKey = true
    scene = SceneState()
  }

  /// Saves the IP of the Arduino UNO Q (tap the scenario badge).
  func updateArduinoHost(_ host: String) {
    let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    arduinoHost = trimmed
    arduino.setHost(trimmed)
    arduinoError = nil
  }

  private func handleScene(_ state: SceneState) {
    let previous = scene.label
    scene = state
    // Only trust successful answers; on errors keep the last known value.
    if state.status == .ok {
      if let seen = state.lookedDevice {
        lookedDevice = seen
        arduinoMisses = 0
      } else {
        arduinoMisses += 1
        if arduinoMisses >= arduinoMissesToForget { lookedDevice = nil }
      }
      syncEye()
    }
    // Room automation runs only when the (stable) scenario CHANGES, so a manual
    // change with the fingers is kept until the next scenario change.
    if let label = state.label, label != previous { applySceneAutomation(label) }
  }

  /// What the room does by itself when the scenario changes (and says it out loud
  /// through the glasses' speakers):
  /// - Studying  → lamp 1 at 75 % (focus light).
  /// - Brainrot  → a spoken nudge to get back to work; lamp 1 at 100 %.
  /// - Walking   → the wearer is leaving: both lamps off.
  /// - Anything else → lamp 1 at 100 %.
  private func applySceneAutomation(_ label: SceneLabel) {
    switch label {
    case .studying:
      setLamp(.lamp1, 75)
      automationNote = "Mode estudi → Llum 1 al 75%"
      Speaker.shared.say("Mode estudi activat.")
    case .brainrot:
      setLamp(.lamp1, 100)
      automationNote = "Distracció → avís a les ulleres"
      Speaker.shared.say("Ei, el mòbil pot esperar. Tornem a estudiar?")
    case .walking:
      setLamp(.lamp1, 0)
      setLamp(.lamp2, 0)
      automationNote = "Marxes → llums apagats"
      Speaker.shared.say("Surts? Apago els llums.")
    default:
      setLamp(.lamp1, 100)
      automationNote = "\(label.title) -> Llum 1 al 100%"
    }
  }

  /// The eye on the Arduino's matrix opens while Gemini has the board in view
  /// (hand controls armed) and closes when it doesn't.
  /// Sent on every Gemini answer (one tiny request every 2 s on the local
  /// network), not only when it changes: that way the eye recovers by itself if
  /// the Arduino app is restarted, if the board resets, or if a request is lost.
  private func syncEye() {
    eyeOpen = lookedDevice != nil
    arduino.setEye(eyeOpen)
  }

  private func setLamp(_ device: SmartDevice, _ level: Int) {
    deviceLevels[device] = Float(level) / 100
    sendToArduino(device, level: level)
  }

  /// A hand in the LEFT half of the image is the left hand (the glasses look the
  /// same way as the wearer). More predictable than MediaPipe's handedness label,
  /// which is swapped for a non-mirrored camera.
  private static func isLeftHand(_ hand: TrackedHand) -> Bool {
    (hand.image.first?.x ?? 0.5) < 0.5
  }

  /// Hand control (only while Gemini has the Arduino in view):
  /// - LEFT hand picks the lamp, and the choice is kept: 1 finger = lamp 1, 2 = lamp 2.
  /// - RIGHT hand, open (5 fingers) and held: +20 % every 2 s.
  /// - RIGHT hand, fist, held: -20 % every 2 s.
  /// - Clap (both hands together): both lamps off.
  private func handleHands(_ frame: HandsFrame) {
    let leftHands = frame.hands.filter { Self.isLeftHand($0) }
    let rightHands = frame.hands.filter { !Self.isLeftHand($0) }
    let now = Date()

    let debug =
      frame.hands.isEmpty
      ? "cap mà"
      : frame.hands.map { hand in
        let side = Self.isLeftHand(hand) ? "ESQ" : "DRETA"
        let fingers = FingerCountGesture.extendedFingers(hand).map(String.init) ?? "?"
        let x = Int(((hand.image.first?.x ?? 0) * 100).rounded())
        return "\(side): \(fingers) dits (x=\(x)%)"
      }.joined(separator: " | ")
    if debug != handsDebug { handsDebug = debug }

    // 0. Clap: two hands whose palms are (almost) touching → both lamps off.
    if frame.hands.count >= 2, frame.hands[0].image.count == 21, frame.hands[1].image.count == 21,
      simd_distance(frame.hands[0].image[9], frame.hands[1].image[9]) < 0.18
    {
      clapFrames += 1
      if clapFrames >= 2, lookedDevice != nil, now.timeIntervalSince(lastClap) > 2 {
        lastClap = now
        setLamp(.lamp1, 0)
        setLamp(.lamp2, 0)
        levelGesture = LevelGestureState()
        Speaker.shared.say("Llums apagats")
      }
      holdDirection = 0
      return  // hands together: ignore the other gestures
    }
    clapFrames = 0

    // 1. Left hand: choose the lamp.
    if let count = selectorFingers.update(HandsFrame(id: frame.id, hands: leftHands)) {
      let pick: SmartDevice? = count == 1 ? .lamp1 : (count == 2 ? .lamp2 : nil)
      if let pick, pick != selectedDevice {
        selectedDevice = pick
        holdDirection = 0
        Speaker.shared.say(pick == .lamp1 ? "Llum un" : "Llum dos")
      }
    }

    // 2. Right hand: open hand = up, fist = down, one step every `holdSeconds`.
    let count = rightHands.first.flatMap(FingerCountGesture.extendedFingers)
    let direction = count == 5 ? 1 : (count == 0 ? -1 : 0)
    if direction != holdDirection {
      holdDirection = direction
      holdSince = now
    }

    var state = LevelGestureState()
    state.fingers = count
    if direction != 0 {
      if let device = selectedDevice, lookedDevice != nil {
        state.active = true
        state.device = device
        state.level = deviceLevels[device] ?? 0
        state.lastStep = direction
        if now.timeIntervalSince(holdSince) >= holdSeconds {
          holdSince = now
          let newLevel = min(1, max(0, state.level + Float(direction) * holdStep))
          if newLevel != state.level {
            state.level = newLevel
            setLamp(device, Int((newLevel * 100).rounded()))
          }
        }
      } else if selectedDevice == nil {
        state.needsSelection = true
      } else {
        state.blockedNoDevice = true
      }
    }
    if state != levelGesture { levelGesture = state }
  }

  private func sendToArduino(_ device: SmartDevice, level: Int) {
    arduino.send(device: device, level: level) { [weak self] error in
      Task { @MainActor [weak self] in
        self?.arduinoError = error
        if error == nil { self?.arduinoLastSentLevel = level }
      }
    }
  }

  // MARK: - Lifecycle step 1: session

  /// Creates and starts a `DeviceSession` (no stream yet). This is the first
  /// explicit step — a session can stay connected with no active stream. The
  /// state observer drives `sessionState`; we only seed an optimistic
  /// `.starting` so the UI reflects the in-flight request immediately.
  func startSession() {
    guard !hasSession else { return }
    do throws(DeviceSessionError) {
      let session = try wearables.createSession(deviceSelector: deviceSelector)
      deviceSession = session
      // Subscribe before start() so no initial state transitions are missed.
      observeSession(session)
      // Reflect the in-flight request immediately; the observer drives it onward.
      sessionState = .starting
      try session.start()
    } catch {
      handleSessionError(error)
      sessionState = .idle
      cleanupSession()
    }
  }

  /// Stops the stream (if any) and ends the device session. `stop()` is terminal;
  /// the SDK cascades the stop to the stream and the state observers clean up
  /// when `.stopped` arrives.
  func endSession() {
    guard let session = deviceSession else { return }
    // Reflect the in-flight stop immediately so the controls disable at once; the
    // state observer drives it onward to `.stopped`.
    sessionState = .stopping
    session.stop()
  }

  // MARK: - Lifecycle step 2: stream

  /// Adds a `Stream` to the started session and starts it. Requires a session in
  /// `.started`. Camera permission is checked first (a query, no redirect); if it
  /// isn't already granted, the actual request — which redirects to the Meta AI
  /// app — is deferred to `confirmCameraPermissionRedirect()` so the app-switch is
  /// confirmed, not a surprise.
  func startStreaming() async {
    guard let session = deviceSession, session.state == .started else {
      showError("Start a session before previewing.")
      return
    }
    guard camera == nil else { return }

    do {
      if try await wearables.checkPermissionStatus(.camera) == .granted {
        beginStream(on: session)
      } else {
        showCameraPermissionRedirectConfirm = true
      }
    } catch {
      showError(error.localizedDescription)
    }
  }

  /// Confirmed from the permission prompt: requests camera access — this opens the
  /// Meta AI app and resumes when the user returns — then starts the stream if
  /// access was granted.
  func confirmCameraPermissionRedirect() async {
    showCameraPermissionRedirectConfirm = false
    guard let session = deviceSession, session.state == .started, camera == nil else { return }
    do {
      guard try await wearables.requestPermission(.camera) == .granted else {
        showError("Camera permission denied")
        return
      }
    } catch {
      showError(error.localizedDescription)
      return
    }
    beginStream(on: session)
  }

  /// Creates the camera `Stream` on the started session and starts it. Callers
  /// must have ensured camera permission is granted first.
  private func beginStream(on session: DeviceSession) {
    guard camera == nil else { return }
    // hvc1 (compressed HEVC) so frames can be written to file in passthrough mode.
    // Glasses-mic (Bluetooth HFP) audio for sound-in-video is captured app-side by
    // AudioCaptureHandler, so the SDK stream needs only the public video config (no audio codec).
    let config = StreamConfiguration(
      videoCodec: VideoCodec.hvc1,
      resolution: StreamingResolution.low,
      // 15 fps is plenty for hand tracking and Gemini (1 frame / 2 s), and keeps
      // the glasses cooler and the battery lasting longer than 24 fps.
      frameRate: 15
    )

    do {
      // Add the consolidated `Camera` capability and stream through `camera.stream`.
      guard let newCamera = try session.addCamera(config: config) else {
        showError("Couldn't create the camera. Try again.")
        return
      }
      camera = newCamera
      // Subscribe before start() so no initial state transitions are missed.
      setupStreamListeners(for: newCamera.stream)
      // Reflect the in-flight request immediately; the observer drives it onward.
      streamState = .starting
      newCamera.stream.start()
    } catch {
      camera = nil
      showError(error.localizedDescription)
    }
  }

  /// Stops the camera stream but keeps the `DeviceSession` connected, so
  /// streaming can be started again without re-creating the session. The stream
  /// `.stopped` observer performs the teardown — we don't eagerly reset here.
  func stopStreaming() {
    guard let activeCamera = camera else { return }
    videoRecorder.prepareToStop()
    // Reflect the in-flight request immediately; the observer drives it onward.
    streamState = .stopping
    // Stopping the camera cascades to its stream child and detaches the camera from the
    // session, so streaming can be started again with a fresh `addCamera()`.
    activeCamera.stop()
  }

  // MARK: - Capture

  func capturePhoto() {
    guard !isCapturingPhoto, isStreaming else {
      showError(photoCaptureFailureMessage)
      return
    }
    isCapturingPhoto = true
    let success = camera?.stream.capturePhoto(format: .jpeg) ?? false
    if !success {
      isCapturingPhoto = false
      showError(photoCaptureFailureMessage)
    }
  }

  func toggleRecording() {
    if isRecording {
      Task { await stopVideoRecording() }
    } else {
      startVideoRecording()
    }
  }

  func startVideoRecording() {
    guard isStreaming, !isRecording else { return }
    // Flip the intent flag synchronously so the toggle and UI don't lag the
    // frame-driven recorder; the file starts on the next frame.
    isRecording = true
    // If the glasses mic isn't available, flip the mic off so the button reflects that this
    // recording is video-only (the phone mic is never used). Left off afterward — the user can
    // re-tap the mic to turn it back on.
    videoRecorder.prepareToStart(includeAudio: includeAudioInStream) { [weak self] in
      Task { @MainActor in self?.includeAudioInStream = false }
    }
  }

  func stopVideoRecording() async {
    guard isRecording else { return }
    isRecording = false
    recordingStartDate = nil
    // The writer starts on the first frame after the shutter opens. If stop lands
    // before that frame arrives, wait briefly (shutter still open) so even a quick
    // recording finalizes to a file and reliably opens the preview.
    var elapsedNanos: UInt64 = 0
    while !videoRecorder.isRecording, elapsedNanos < 500_000_000 {
      try? await Task.sleep(nanoseconds: 25_000_000)
      elapsedNanos += 25_000_000
    }
    // Show a preview/share sheet (mirrors the photo flow) for the finalized file.
    switch await videoRecorder.stopRecording() {
    case .completed(let url):
      activePreview = .video(url)
    case .noRecording:
      // Reached only after the intent guard + start wait, so while streaming this
      // means the recording never started (e.g. the writer failed to start).
      showError("Couldn't start recording. Try again.")
    case .failed:
      showError("Recording couldn't be saved. Try again.")
    }
  }

  // MARK: - Dismissers

  func dismissError() {
    showError = false
  }

  func dismissCapturePreview() {
    guard let preview = activePreview else { return }
    activePreview = nil
    discardPreview(preview)
  }

  /// Deletes a finished video capture's temporary file. Photos are held in
  /// memory, so there's nothing on disk to remove for them.
  func discardPreview(_ preview: CapturePreview) {
    if case .video(let url) = preview {
      try? FileManager.default.removeItem(at: url)
    }
  }

  // MARK: - Device monitoring

  /// Monitors device availability only — does NOT create sessions. Session
  /// creation is deferred to `startSession()` to avoid races.
  private func startDeviceMonitoring() {
    deviceMonitorTask = Task { [weak self] in
      guard let self else { return }
      for await deviceId in deviceSelector.activeDeviceStream() {
        hasActiveDevice = deviceId != nil
      }
    }
  }

  private func startAppLifecycleMonitoring() {
    appLifecycleTask = Task { [weak self] in
      guard let self else { return }
      for await _ in NotificationCenter.default.notifications(named: UIApplication.didEnterBackgroundNotification) {
        self.handleDidEnterBackground()
      }
    }
  }

  private func handleDidEnterBackground() {
    guard hasSession, hasStream, sessionState != .stopping else { return }

    beginBackgroundStopErrorSuppression()
    endSession()
  }

  private func beginBackgroundStopErrorSuppression() {
    isStoppingForBackground = true
    backgroundStopSuppressionTask?.cancel()
    let timeout = backgroundStopErrorSuppressionTimeout
    backgroundStopSuppressionTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: timeout)
      guard let self, !Task.isCancelled else { return }
      // Bound the suppression window so a stalled teardown cannot hide
      // unrelated later errors indefinitely.
      self.isStoppingForBackground = false
      self.backgroundStopSuppressionTask = nil
    }
  }

  private func endBackgroundStopErrorSuppression() {
    backgroundStopSuppressionTask?.cancel()
    backgroundStopSuppressionTask = nil
    isStoppingForBackground = false
  }

  // MARK: - Session observation

  private func observeSession(_ session: DeviceSession) {
    session.statePublisher.listen { [weak self] state in
      Task { @MainActor in self?.handleSessionStateChange(state) }
    }.store(in: sessionTokenBag)
    session.errorPublisher.listen { [weak self] error in
      Task { @MainActor in self?.handleSessionError(error) }
    }.store(in: sessionTokenBag)
  }

  private func handleSessionStateChange(_ state: DeviceSessionState) {
    sessionState = state
    if state == .stopped {
      endBackgroundStopErrorSuppression()
      cleanupSession()
    }
  }

  private func handleSessionError(_ error: DeviceSessionError) {
    // Backgrounding the app intentionally ends the preview session; the SDK can
    // still emit teardown errors while that stop converges, and surfacing those
    // would show a false "something went wrong" alert on return.
    guard !isStoppingForBackground else { return }
    // All session errors surface through the single alert, including
    // `datAppOnTheGlassesUpdateRequired`, which the SDK delivers as a one-shot event.
    showError(error.localizedDescription)
  }

  /// Terminal session cleanup — drop the reference and observers so the next
  /// `startSession()` creates a fresh session.
  private func cleanupSession() {
    sessionTokenBag.clear()
    deviceSession = nil
  }

  // MARK: - Stream observation

  private func setupStreamListeners(for stream: MWDATCamera.Stream) {
    stream.statePublisher.listen { [weak self] state in
      Task { @MainActor in self?.handleStreamStateChange(state) }
    }.store(in: streamTokenBag)

    stream.videoFramePublisher.listen { [weak self] frame in
      guard let self else { return }

      // Append to the recorder (no-op unless recording) off the main actor so it
      // keeps writing while the app is backgrounded.
      self.appendVideoFrame(frame)

      // Decode the compressed hvc1 frame for preview off the main actor.
      let previewImage = self.videoFrameDecoder.decode(frame.sampleBuffer)

      // Every 2 s, send the frame to Gemini to recognise the scenario.
      if let previewImage {
        self.sceneDetector.process(previewImage) { [weak self] state in
          Task { @MainActor [weak self] in self?.handleScene(state) }
        }
        // Hand tracking for the finger-count gesture.
        self.handTracker.process(previewImage) { [weak self] hands in
          Task { @MainActor [weak self] in self?.handleHands(hands) }
        }
      }

      Task { @MainActor [weak self] in
        guard let self else { return }
        // Keep the live surface stable while a capture preview is onscreen.
        if UIApplication.shared.applicationState != .background,
          activePreview == nil,
          !isCapturingPhoto,
          let image = previewImage
        {
          self.currentVideoFrame = image
          if !self.hasReceivedFirstFrame {
            self.hasReceivedFirstFrame = true
          }
        }
        // Capture the actual recording start (first written frame) once, so the timer
        // anchors to the clip's start and matches its duration.
        if self.isRecording, self.recordingStartDate == nil {
          self.recordingStartDate = self.videoRecorder.recordingStartDate
        }
      }
    }.store(in: streamTokenBag)

    stream.errorPublisher.listen { [weak self] error in
      Task { @MainActor in self?.handleStreamError(error) }
    }.store(in: streamTokenBag)

    stream.photoDataPublisher.listen { [weak self] data in
      Task { @MainActor in self?.handlePhotoData(data) }
    }.store(in: streamTokenBag)
  }

  private func handleStreamStateChange(_ state: StreamState) {
    streamState = state
    if state == .stopped {
      // Terminal — finalize any recording, then converge teardown. Covers both
      // user-initiated stop and SDK auto-stop (disconnect, error, session end).
      Task { await stopVideoRecording() }
      clearStreamResources()
    }
  }

  /// Single stream-teardown convergence point.
  private func clearStreamResources() {
    streamTokenBag.clear()
    // Detach the camera (idempotent) so a subsequent addCamera() can register a new one. On the
    // user-stop and session-end paths the camera is already stopped, so this is a no-op; it is
    // load-bearing only when the stream terminates on its own (a stream-level error while the
    // session stays connected), since teardown cascades parent->child but not child->parent.
    camera?.stop()
    camera = nil
    streamState = .stopped
    currentVideoFrame = nil
    hasReceivedFirstFrame = false
    scene = SceneState()
    sceneDetector.reset()
    automationNote = nil
    selectorFingers.reset()
    holdDirection = 0
    clapFrames = 0
    lookedDevice = nil
    arduinoMisses = 0
    syncEye()
    levelGesture.active = false
  }

  /// Appends a frame to the recorder. `nonisolated` so it keeps writing while the
  /// app is backgrounded (the recorder is thread-safe).
  nonisolated private func appendVideoFrame(_ frame: VideoFrame) {
    videoRecorder.appendVideoFrame(frame.sampleBuffer)
  }

  private func handleStreamError(_ error: StreamError) {
    // Same bounded suppression window as `handleSessionError`: hide only the
    // expected teardown noise from an intentional background-driven stop.
    guard !isStoppingForBackground else { return }
    showError(error.localizedDescription)
  }

  private func handlePhotoData(_ data: PhotoData) {
    isCapturingPhoto = false
    if let image = UIImage(data: data.data) {
      activePreview = .photo(image)
    }
  }

  private func showError(_ message: String) {
    errorMessage = message
    showError = true
  }
}


// MARK: - Scene recognition (Gemini API)

/// Scenarios Gemini can choose from. Raw values are exactly what the model answers.
enum SceneLabel: String, Sendable, CaseIterable {
  case studying = "estudiant"
  case cooking = "cuinant"
  case reading = "llegint"
  case brainrot = "brainrot"
  case social = "social"
  case teamwork = "treball_en_equip"
  case laptopDistraction = "distraccio_portatil"
  case eating = "menjant"
  case coffee = "cafe"
  case resting = "descansant"
  case talk = "xerrada"
  case walking = "caminant"
  case other = "altres"

  var title: String {
    switch self {
    case .studying: "Estudiant"
    case .cooking: "Cuinant"
    case .reading: "Llegint"
    case .brainrot: "Brainrot"
    case .social: "Social"
    case .teamwork: "Treball en equip"
    case .laptopDistraction: "Distracció al portàtil"
    case .eating: "Menjant"
    case .coffee: "Cafè"
    case .resting: "Descansant"
    case .talk: "Xerrada"
    case .walking: "Caminant"
    case .other: "Altres"
    }
  }

  /// How the model should recognise it (English works best for the model).
  var hint: String {
    switch self {
    case .studying: "at a desk with a laptop/computer and books, notes or paper; studying or working"
    case .cooking: "in a kitchen preparing food: cutting, stirring, pans, stove, ingredients"
    case .reading: "holding or looking at a book, e-reader or printed text up close"
    case .brainrot: "scrolling a phone: short videos, social media feeds (TikTok, Instagram, Reels...)"
    case .social: "with other people chatting or hanging out, faces in front of them (not working together, not mainly eating)"
    case .teamwork: "2+ people working together on one laptop, screen, whiteboard or paper (working, not just chatting)"
    case .laptopDistraction: "a laptop/computer screen showing YouTube, Netflix, social media, memes or a game (not study or work material)"
    case .eating: "eating: food, pizza, snacks or a plate in front of them or in their hand"
    case .coffee: "a coffee break: holding a coffee cup or mug, not working (a quick sip while studying is not a break)"
    case .resting: "resting: lying or slouched on a sofa, beanbag or chair, looking at the ceiling or around, no screens"
    case .talk: "attending a talk or workshop: audience, stage, speaker, projector or big screen in front"
    case .walking: "walking: corridor, stairs, street or floor ahead, moving between places"
    case .other: "none of the above"
    }
  }
}

/// What the UI shows.
struct SceneState: Sendable, Equatable {
  enum Status: Sendable, Equatable {
    case idle  // nothing sent yet
    case ok  // last request answered
    case error(String)
  }
  /// Stable scenario shown to the user (only changes after `requiredRepeats` frames).
  var label: SceneLabel?
  /// Gemini's short explanation for the last frame (Catalan).
  var reason: String = ""
  /// The last frame was a brief glance away that was ignored.
  var briefInterruption = false
  /// A different scenario was seen `pendingCount` times in a row (0 = none).
  var pendingLabel: SceneLabel?
  var pendingCount = 0
  var status: Status = .idle
  var latencyMs = 0
  /// Smart device the wearer is looking at in the last frame (nil = none).
  var lookedDevice: SmartDevice?
}

/// Every `interval` seconds sends the latest glasses frame to the Gemini API and
/// asks which scenario the wearer is in. The model is told the current scenario
/// so it can mark a quick glance (e.g. at someone walking by) as a brief
/// interruption, and the scenario only switches after `requiredRepeats` frames
/// in a row show the new one.
final class GeminiSceneDetector: @unchecked Sendable {
  static let model = "gemini-3.5-flash-lite"

  // POSA AQUÍ LA CLAU DE GEMINI (entre les cometes).
  // No pugis aquest fitxer a GitHub amb la clau escrita: esborra-la abans.
  static let hardcodedKey = ""

  static let keyDefaultsKey = "geminiApiKey"
  /// Key typed in the app (tap the badge) wins; otherwise the one written above.
  static var savedKey: String? {
    let typed = UserDefaults.standard.string(forKey: keyDefaultsKey) ?? ""
    if !typed.isEmpty { return typed }
    return hardcodedKey.isEmpty ? nil : hardcodedKey
  }

  let interval: TimeInterval = 2.0
  /// After a 429 (too many requests) wait this long before sending again.
  let rateLimitPause: TimeInterval = 10
  let requiredRepeats = 2

  private let lock = NSLock()
  private var busy = false
  private var lastSent = Date.distantPast
  private var pausedUntil = Date.distantPast
  private var apiKey = GeminiSceneDetector.savedKey
  private var stable: SceneLabel?
  private var stableFrames = 0
  private var candidate: SceneLabel?
  private var candidateCount = 0
  private var generation = 0  // bumped on reset so late answers are ignored

  private let session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 15
    return URLSession(configuration: config)
  }()

  private static let prompt: String =
    "You see input from smart glasses worn by a person (first-person view).\n"
    + "Decide which SCENARIO the wearer is in right now, looking at the whole scene "
    + "(objects, place, what their hands are doing), not just a single object.\n"
    + "Scenarios:\n"
    + SceneLabel.allCases.map { "- \($0.rawValue): \($0.hint)" }.joined(separator: "\n")
    + "\nIf two could fit, pick the one that best describes what the wearer is actively doing."
    + "\nAlso give a short reason in Catalan (max 15 words) describing what you see."
    + "\nSeparately, set dispositiu_mirat to the smart device the wearer is looking at, i.e. "
    + "the one closest to the CENTRE of the image (it does not change the scenario):\n"
    + SmartDevice.allCases.map { "- \($0.rawValue): \($0.hint)" }.joined(separator: "\n")
    + "\n- cap: none of them is in view."
    + "\nIf a hand partially covers the board or only part of it is visible, it still counts: "
    + "answer the device you can see, not 'cap'."

  private static func context(_ current: SceneLabel?, frames: Int) -> String {
    guard let current else {
      return "\nThere is no previous context. Set breu_interrupcio=false."
    }
    let c = current.rawValue
    return "\nCONTEXT: for the last \(frames) frames the wearer has been in scenario '\(c)'. "
      + "Rules:\n"
      + "1. A brief, harmless glance away is NOT a change: looking at someone who walks by or says hi, "
      + "looking out of the window, taking a sip of water. In that case set breu_interrupcio=true "
      + "and activitat='\(c)'.\n"
      + "2. A distraction is never a brief interruption. If the wearer is holding or looking at a "
      + "phone screen (scrolling, videos, social media, chats), answer activitat='brainrot'; if a "
      + "laptop shows YouTube, Netflix, social media or a game, answer 'distraccio_portatil'. In both "
      + "cases breu_interrupcio=false, even if they were studying before. Detecting these "
      + "distractions is the main goal.\n"
      + "3. Otherwise set breu_interrupcio=false and answer the scenario you really see, if the scene "
      + "clearly shows a different activity (they left the desk, are cooking, sat down with a group)."
  }

  func setKey(_ key: String) {
    UserDefaults.standard.set(key, forKey: Self.keyDefaultsKey)
    lock.lock()
    apiKey = key.isEmpty ? nil : key
    lastSent = .distantPast
    lock.unlock()
  }

  func reset() {
    lock.lock()
    generation += 1
    stable = nil
    stableFrames = 0
    candidate = nil
    candidateCount = 0
    busy = false
    lastSent = .distantPast
    lock.unlock()
  }

  func process(_ image: UIImage, completion: @escaping @Sendable (SceneState) -> Void) {
    lock.lock()
    if busy || Date().timeIntervalSince(lastSent) < interval || Date() < pausedUntil {
      lock.unlock()
      return
    }
    lastSent = Date()
    guard let key = apiKey else {
      lock.unlock()
      completion(SceneState(status: .error("Toca aquí per posar la clau de Gemini")))
      return
    }
    busy = true
    let gen = generation
    let context = Self.context(stable, frames: stableFrames)
    lock.unlock()

    guard let jpeg = Self.smallJPEG(image, maxSide: 768),
      let url = URL(
        string:
          "https://generativelanguage.googleapis.com/v1beta/models/\(Self.model):generateContent")
    else {
      lock.lock()
      busy = false
      lock.unlock()
      return
    }

    let schema: [String: Any] = [
      "type": "OBJECT",
      "properties": [
        "activitat": ["type": "STRING", "enum": SceneLabel.allCases.map(\.rawValue)],
        "breu_interrupcio": ["type": "BOOLEAN"],
        "motiu": ["type": "STRING"],
        "dispositiu_mirat": [
          "type": "STRING", "enum": SmartDevice.allCases.map(\.rawValue) + ["cap"],
        ],
      ],
      "required": ["activitat", "breu_interrupcio", "motiu", "dispositiu_mirat"],
      "propertyOrdering": ["activitat", "breu_interrupcio", "motiu", "dispositiu_mirat"],
    ]
    let body: [String: Any] = [
      "contents": [
        [
          "role": "user",
          "parts": [
            ["inlineData": ["mimeType": "image/jpeg", "data": jpeg.base64EncodedString()]],
            ["text": Self.prompt + context],
          ],
        ]
      ],
      "generationConfig": [
        "temperature": 0,
        "responseMimeType": "application/json",
        "responseSchema": schema,
      ],
    ]
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)

    let started = Date()
    session.dataTask(with: request) { [weak self] data, response, error in
      guard let self else { return }
      let latency = Int(Date().timeIntervalSince(started) * 1000)
      let state: SceneState?
      if let error {
        state = self.finish(
          gen: gen, answer: nil, latencyMs: latency,
          error: "Sense connexió: \(error.localizedDescription)")
      } else if let http = response as? HTTPURLResponse, http.statusCode == 429 {
        // Too many requests for this key: slow down instead of failing in a loop.
        self.lock.lock()
        self.pausedUntil = Date().addingTimeInterval(self.rateLimitPause)
        self.lock.unlock()
        state = self.finish(
          gen: gen, answer: nil, latencyMs: latency,
          error: "Massa peticions (límit de la clau): espero \(Int(self.rateLimitPause)) s")
      } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
        state = self.finish(
          gen: gen, answer: nil, latencyMs: latency,
          error: "Gemini \(http.statusCode): \(Self.apiErrorMessage(data))")
      } else if let answer = Self.parse(data) {
        state = self.finish(gen: gen, answer: answer, latencyMs: latency, error: nil)
      } else {
        state = self.finish(
          gen: gen, answer: nil, latencyMs: latency, error: "Resposta de Gemini no reconeguda")
      }
      if let state { completion(state) }
    }.resume()
  }

  private struct Answer {
    let label: SceneLabel
    let brief: Bool
    let reason: String
    let device: SmartDevice?
  }

  /// Context + "sticky" switching. Returns nil if a reset happened in between.
  private func finish(gen: Int, answer: Answer?, latencyMs: Int, error: String?) -> SceneState? {
    lock.lock()
    defer { lock.unlock() }
    busy = false
    guard gen == generation else { return nil }

    var reason = ""
    var brief = false
    if let answer {
      reason = answer.reason
      // A distraction (phone or laptop) is never "brief": it always counts as a real change.
      brief = answer.brief && stable != nil
        && answer.label != .brainrot && answer.label != .laptopDistraction
      if stable == nil {
        stable = answer.label
        stableFrames = 1
      } else if brief || answer.label == stable {
        stableFrames += 1
        candidate = nil
        candidateCount = 0
      } else {
        if answer.label == candidate {
          candidateCount += 1
        } else {
          candidate = answer.label
          candidateCount = 1
        }
        if candidateCount >= requiredRepeats {
          stable = candidate
          stableFrames = candidateCount
          candidate = nil
          candidateCount = 0
        } else {
          stableFrames += 1
        }
      }
    }
    return SceneState(
      label: stable,
      reason: reason,
      briefInterruption: brief,
      pendingLabel: candidate,
      pendingCount: candidateCount,
      status: error.map { .error($0) } ?? .ok,
      latencyMs: latencyMs,
      lookedDevice: answer?.device)
  }

  private static func parse(_ data: Data?) -> Answer? {
    guard let data,
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let candidates = json["candidates"] as? [[String: Any]],
      let content = candidates.first?["content"] as? [String: Any],
      let parts = content["parts"] as? [[String: Any]]
    else { return nil }
    // Join only the text parts (skips the hidden "thoughtSignature" part).
    let text = parts.compactMap { $0["text"] as? String }.joined()
    guard let inner = text.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: inner) as? [String: Any],
      let value = object["activitat"] as? String,
      let label = SceneLabel(rawValue: value)
    else { return nil }
    return Answer(
      label: label,
      brief: object["breu_interrupcio"] as? Bool ?? false,
      reason: object["motiu"] as? String ?? "",
      device: (object["dispositiu_mirat"] as? String).flatMap(SmartDevice.init(rawValue:)))
  }

  private static func apiErrorMessage(_ data: Data?) -> String {
    if let data,
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let error = json["error"] as? [String: Any],
      let message = error["message"] as? String
    {
      return String(message.prefix(90))
    }
    return "error desconegut"
  }

  /// Downscales with CoreGraphics (thread-safe) and encodes as JPEG.
  private static func smallJPEG(_ image: UIImage, maxSide: CGFloat) -> Data? {
    guard let cg = image.cgImage else { return image.jpegData(compressionQuality: 0.7) }
    let w = CGFloat(cg.width)
    let h = CGFloat(cg.height)
    let scale = min(1, maxSide / max(w, h))
    let tw = Int(w * scale)
    let th = Int(h * scale)
    guard
      let ctx = CGContext(
        data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    ctx.interpolationQuality = .medium
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: tw, height: th))
    guard let small = ctx.makeImage() else { return nil }
    return UIImage(cgImage: small).jpegData(compressionQuality: 0.7)
  }
}
// MARK: - Hand tracking (MediaPipe Hand Landmarker)

/// One detected hand: 21 landmarks in metres (world, hand-centred) and in
/// normalised image coordinates (0...1).
struct TrackedHand: Sendable, Equatable {
  var world: [SIMD3<Float>]
  var image: [SIMD2<Float>]
  var label: String
}

/// All hands detected in one frame. `id` increments every result so SwiftUI
/// `onChange` fires even when the hand count stays the same.
struct HandsFrame: Sendable, Equatable {
  var id: Int = 0
  var hands: [TrackedHand] = []
}

/// Wraps MediaPipe's `HandLandmarker` in VIDEO mode on a serial queue. If a frame
/// arrives while the previous one is still being processed, it is dropped, so the
/// tracker never falls behind the live stream.
final class HandTracker: @unchecked Sendable {
  private let queue = DispatchQueue(label: "hand-tracker", qos: .userInitiated)
  private let lock = NSLock()
  private var busy = false
  private var landmarker: HandLandmarker?
  private var frameId = 0
  private var lastTimestamp = 0

  init() {
    queue.async { [self] in setUp() }
  }

  private func setUp() {
    guard let path = Bundle.main.path(forResource: "hand_landmarker", ofType: "task") else {
      print("[HandTracker] hand_landmarker.task not found in the app bundle — add it to the CameraAccess target")
      return
    }
    do {
      let options = HandLandmarkerOptions()
      options.baseOptions.modelAssetPath = path
      options.runningMode = .video
      options.numHands = 2
      options.minHandDetectionConfidence = 0.5
      options.minHandPresenceConfidence = 0.5
      options.minTrackingConfidence = 0.5
      landmarker = try HandLandmarker(options: options)
      print("[HandTracker] MediaPipe Hand Landmarker ready")
    } catch {
      print("[HandTracker] Failed to create HandLandmarker: \(error)")
    }
  }

  func process(_ image: UIImage, completion: @escaping @Sendable (HandsFrame) -> Void) {
    lock.lock()
    if busy { lock.unlock(); return }
    busy = true
    lock.unlock()

    queue.async { [self] in
      defer { lock.lock(); busy = false; lock.unlock() }
      guard let landmarker else { return }

      // VIDEO mode needs strictly increasing timestamps.
      let now = Int(Date().timeIntervalSince1970 * 1000)
      let timestamp = max(now, lastTimestamp + 1)
      lastTimestamp = timestamp

      guard let mpImage = try? MPImage(uiImage: image),
        let result = try? landmarker.detect(videoFrame: mpImage, timestampInMilliseconds: timestamp)
      else { return }

      var hands: [TrackedHand] = []
      for i in 0..<result.landmarks.count {
        let imagePoints = result.landmarks[i].map { SIMD2<Float>($0.x, $0.y) }
        let worldPoints: [SIMD3<Float>] =
          i < result.worldLandmarks.count
          ? result.worldLandmarks[i].map { SIMD3<Float>($0.x, $0.y, $0.z) }
          : imagePoints.map { SIMD3<Float>(($0.x - 0.5) * 0.2, ($0.y - 0.5) * 0.2, 0) }
        let label = (i < result.handedness.count ? result.handedness[i].first?.categoryName : nil) ?? "Hand"
        hands.append(TrackedHand(world: worldPoints, image: imagePoints, label: label))
      }
      frameId += 1
      completion(HandsFrame(id: frameId, hands: hands))
    }
  }
}


// MARK: - hand gestures

/// What the UI shows about the finger-count gesture.
struct LevelGestureState: Sendable, Equatable {
  var active = false  // a hand is up and controlling a device
  var device: SmartDevice?  // which device it controls (chosen when the gesture starts)
  var level: Float = 0  // 0...1 of that device
  var lastStep = 0  // +1 went up, -1 went down, 0 none (for the arrow)
  var fingers: Int?  // fingers counted right now (live feedback)
  var blockedNoDevice = false  // hand seen, but the wearer isn't looking at the Arduino
  var needsSelection = false  // right hand up, but no device chosen with the left hand yet
}

/// The devices on the Arduino that can be looked at and controlled.
/// Raw value = what Gemini answers; `arduinoName` = what the Arduino app expects.
enum SmartDevice: String, Sendable, CaseIterable {
  case lamp1 = "llum1"
  case lamp2 = "llum2"
  case screen = "pantalla"

  var arduinoName: String {
    switch self {
    case .lamp1: "lamp1"
    case .lamp2: "lamp2"
    case .screen: "screen"
    }
  }

  var title: String {
    switch self {
    case .lamp1: "Llum 1"
    case .lamp2: "Llum 2"
    case .screen: "Pantalla"
    }
  }

  /// How Gemini recognises it (English works best for the model).
  var hint: String {
    switch self {
    case .lamp1: "a small LED next to a card or label reading 'LAMP 1' (or 'LLUM 1')"
    case .lamp2: "a small LED next to a card or label reading 'LAMP 2' (or 'LLUM 2')"
    case .screen: "the Arduino board itself, with its grid of small blue LEDs (LED matrix)"
    }
  }
}

/// "Count fingers" gesture: the number of extended fingers sets the level.
/// 0 = 0 %, 1 = 20 %, 2 = 40 %, 3 = 60 %, 4 = 80 %, 5 = 100 %.
/// A count is only applied once it has been held for `framesStable` frames, so
/// passing through other counts while changing fingers doesn't send anything.
struct FingerCountGesture {
  /// MediaPipe assumes a mirrored selfie image; the glasses' camera is not, so the
  /// right hand is labelled "Left". nil = either hand.
  static let acceptedLabel: String? = nil
  /// Frames the hand must be visible before the gesture starts (15 fps → ~0.25 s).
  static let framesToStart = 4
  /// Frames the same count must be held before it is applied (~0.3 s).
  static let framesStable = 5
  /// Frames without a hand before the gesture ends.
  static let framesToStop = 4

  private(set) var active = false
  /// Fingers counted in the last frame (shown live in the pop-up).
  private(set) var currentCount: Int?
  private var seen = 0
  private var missed = 0
  private var candidate = -1
  private var candidateFrames = 0
  private var lastApplied: Int?

  /// Returns the new finger count (0...5) when a stable count changes, else nil.
  mutating func update(_ frame: HandsFrame) -> Int? {
    let hand = frame.hands.first { Self.acceptedLabel == nil || $0.label == Self.acceptedLabel }
    guard let hand, let count = Self.extendedFingers(hand) else {
      seen = 0
      if active {
        missed += 1
        if missed >= Self.framesToStop { reset() }
      }
      return nil
    }
    missed = 0
    if !active {
      seen += 1
      guard seen >= Self.framesToStart else { return nil }
      active = true
    }
    currentCount = count
    if count == candidate {
      candidateFrames += 1
    } else {
      candidate = count
      candidateFrames = 1
    }
    if candidateFrames >= Self.framesStable, count != lastApplied {
      lastApplied = count
      return count
    }
    return nil
  }

  mutating func reset() {
    active = false
    currentCount = nil
    seen = 0
    missed = 0
    candidate = -1
    candidateFrames = 0
    lastApplied = nil
  }

  /// Counts extended fingers using MediaPipe's world landmarks (metres), so it
  /// works the same whether the hand is near or far from the camera.
  static func extendedFingers(_ hand: TrackedHand) -> Int? {
    let w = hand.world
    guard w.count == 21 else { return nil }
    let palm = simd_distance(w[0], w[9])  // wrist → middle knuckle
    guard palm > 0.001 else { return nil }
    var count = 0
    // Index, middle, ring, pinky: the tip is clearly farther from the wrist than
    // the middle joint when the finger is straight, and closer when it is folded.
    for (tip, pip) in [(8, 6), (12, 10), (16, 14), (20, 18)] {
      if simd_distance(w[0], w[tip]) > simd_distance(w[0], w[pip]) * 1.15 { count += 1 }
    }
    // Thumb: when extended its tip sticks out away from the palm centre (middle
    // knuckle); when folded it lies across the palm, close to it.
    let thumbTipToPalm = simd_distance(w[4], w[9])
    if thumbTipToPalm > palm * 0.8, thumbTipToPalm > simd_distance(w[3], w[9]) { count += 1 }
    return count
  }
}

// MARK: - Arduino UNO Q link

/// Sends the level to the Arduino UNO Q over Wi-Fi. The UNO Q runs a small
/// Python app (Web UI brick) that receives `GET /level?value=NN` and draws a
/// battery on its LED matrix through the Router Bridge.
final class ArduinoLink: @unchecked Sendable {
  /// Port of the App Lab "Web UI" brick (the URL App Lab shows when the app runs).
  static let port = 7000
  static let hostKey = "arduinoHost"
  static var savedHost: String {
    // Example only: set your own board's IP in the app (tap the badge).
    UserDefaults.standard.string(forKey: hostKey) ?? "192.168.1.50"
  }

  private let lock = NSLock()
  private var host = ArduinoLink.savedHost
  private let session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 3
    return URLSession(configuration: config)
  }()

  func setHost(_ newHost: String) {
    UserDefaults.standard.set(newHost, forKey: Self.hostKey)
    lock.lock()
    host = newHost
    lock.unlock()
  }

  /// Opens / closes the eye drawn on the LED matrix.
  func setEye(_ open: Bool) {
    lock.lock()
    let host = self.host
    lock.unlock()
    guard let url = URL(string: "http://\(host):\(Self.port)/device?name=eye&value=\(open ? 1 : 0)")
    else { return }
    session.dataTask(with: url).resume()
  }

  /// Sets one device (0...100). Calls back with nil on success or an error text.
  func send(device: SmartDevice, level: Int, completion: @escaping @Sendable (String?) -> Void) {
    lock.lock()
    let host = self.host
    lock.unlock()
    guard
      let url = URL(
        string: "http://\(host):\(Self.port)/device?name=\(device.arduinoName)&value=\(level)")
    else {
      completion("IP no vàlida: \(host)")
      return
    }
    session.dataTask(with: url) { _, response, error in
      if let error {
        completion("No connecta amb \(host): \(error.localizedDescription)")
      } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
        completion("Arduino \(http.statusCode)")
      } else {
        completion(nil)
      }
    }.resume()
  }
}


// MARK: - Spoken feedback

/// Speaks short messages. While the glasses are connected, iOS plays the audio
/// through their speakers, so the wearer hears it without looking at the phone.
@MainActor
final class Speaker {
  static let shared = Speaker()
  private let synthesizer = AVSpeechSynthesizer()

  func say(_ text: String) {
    synthesizer.stopSpeaking(at: .immediate)
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice =
      AVSpeechSynthesisVoice(language: "ca-ES") ?? AVSpeechSynthesisVoice(language: "es-ES")
    synthesizer.speak(utterance)
  }
}
