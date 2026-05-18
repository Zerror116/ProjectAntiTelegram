import Cocoa
import FlutterMacOS
import Carbon.HIToolbox
import AVFoundation
import CoreImage
import QuartzCore

@main
class AppDelegate: FlutterAppDelegate {
  private let inputLanguageStreamHandler = InputLanguageStreamHandler()
  private var inputLanguageChannelConfigured = false
  private var videoNoteCaptureChannelConfigured = false
  private var inputLanguageConfigureRetries = 0
  private var inputLanguageRetryTimer: Timer?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    configureInputLanguageChannels()
    configureVideoNoteCaptureChannel()
    DispatchQueue.main.async { [weak self] in
      self?.configureInputLanguageChannels()
      self?.configureVideoNoteCaptureChannel()
    }
  }

  override func applicationDidBecomeActive(_ notification: Notification) {
    super.applicationDidBecomeActive(notification)
    configureInputLanguageChannels()
    configureVideoNoteCaptureChannel()
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  private func configureInputLanguageChannels() {
    guard !inputLanguageChannelConfigured else { return }
    guard let flutterViewController = mainFlutterWindow?.contentViewController as? FlutterViewController else {
      scheduleInputLanguageChannelRetry()
      return
    }

    let eventChannel = FlutterEventChannel(
      name: "project_fenix/input_language",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    eventChannel.setStreamHandler(inputLanguageStreamHandler)

    let methodChannel = FlutterMethodChannel(
      name: "project_fenix/input_language_query",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    methodChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "getCurrentLanguage":
        result(InputLanguageStreamHandler.currentLanguageCode())
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    inputLanguageRetryTimer?.invalidate()
    inputLanguageRetryTimer = nil
    inputLanguageConfigureRetries = 0
    inputLanguageChannelConfigured = true
  }

  private func configureVideoNoteCaptureChannel() {
    guard !videoNoteCaptureChannelConfigured else { return }
    guard let flutterViewController = mainFlutterWindow?.contentViewController as? FlutterViewController else {
      scheduleInputLanguageChannelRetry()
      return
    }

    VideoNoteCapturePlugin.shared.register(
      with: flutterViewController.engine.binaryMessenger
    )

    videoNoteCaptureChannelConfigured = true
  }

  private func scheduleInputLanguageChannelRetry() {
    guard !inputLanguageChannelConfigured || !videoNoteCaptureChannelConfigured else { return }
    guard inputLanguageRetryTimer == nil else { return }
    guard inputLanguageConfigureRetries < 40 else { return }
    inputLanguageConfigureRetries += 1
    inputLanguageRetryTimer = Timer.scheduledTimer(
      withTimeInterval: 0.25,
      repeats: false
    ) { [weak self] _ in
      guard let self else { return }
      self.inputLanguageRetryTimer?.invalidate()
      self.inputLanguageRetryTimer = nil
      self.configureInputLanguageChannels()
      self.configureVideoNoteCaptureChannel()
    }
  }
}

final class VideoNoteCapturePlugin {
  static let shared = VideoNoteCapturePlugin()

  private let handler = VideoNoteCaptureHandler()
  private var channel: FlutterMethodChannel?
  private var previewChannel: FlutterEventChannel?

  private init() {}

  func register(with binaryMessenger: FlutterBinaryMessenger) {
    let methodChannel = FlutterMethodChannel(
      name: "project_fenix/video_note_capture",
      binaryMessenger: binaryMessenger
    )
    methodChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(
          code: "video_note_capture_unavailable",
          message: "Video note capture handler is unavailable",
          details: nil
        ))
        return
      }
      self.handler.handle(call, result: result)
    }
    channel = methodChannel

    let eventChannel = FlutterEventChannel(
      name: "project_fenix/video_note_preview",
      binaryMessenger: binaryMessenger
    )
    eventChannel.setStreamHandler(handler)
    previewChannel = eventChannel
  }
}

private final class VideoNoteCaptureHandler: NSObject, AVCaptureFileOutputRecordingDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, FlutterStreamHandler {
  private var session: AVCaptureSession?
  private var movieOutput: AVCaptureMovieFileOutput?
  private var previewOutput: AVCaptureVideoDataOutput?
  private var outputURL: URL?
  private var startedAt: Date?
  private var pendingStopResult: FlutterResult?
  private var cancelOnFinish = false
  private var isRecording = false
  private var isPreviewing = false
  private let previewQueue = DispatchQueue(label: "project_fenix.video_note.preview")
  private let previewContext = CIContext()
  private var previewEventSink: FlutterEventSink?
  private var lastPreviewSentAt: CFTimeInterval = 0
  private var lastPreviewData: Data?

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    previewEventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    previewEventSink = nil
    return nil
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    DispatchQueue.main.async { [weak self] in
      guard let self else {
        result(FlutterError(
          code: "video_note_capture_unavailable",
          message: "Video note capture handler is unavailable",
          details: nil
        ))
        return
      }

      switch call.method {
      case "isSupported":
        result(true)
      case "start":
        self.start(result: result)
      case "startPreview":
        self.startPreview(result: result)
      case "stopPreview":
        self.stopPreview(result: result)
      case "capturePhoto":
        self.capturePhoto(result: result)
      case "stop":
        self.stop(result: result)
      case "cancel":
        self.cancel(result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func start(result: @escaping FlutterResult) {
    guard !isRecording else {
      result(FlutterError(
        code: "video_note_already_recording",
        message: "Video note recording is already active",
        details: nil
      ))
      return
    }

    requestCaptureAccess { [weak self] allowed in
      DispatchQueue.main.async {
        guard let self else { return }
        guard allowed else {
          result(FlutterError(
            code: "video_note_permission_denied",
            message: "Camera or microphone permission denied",
            details: nil
          ))
          return
        }

        do {
          if self.session == nil || self.movieOutput == nil {
            try self.configureSession()
          }
          guard let movieOutput = self.movieOutput else {
            throw NSError(domain: "project_fenix.video_note", code: 1)
          }
          let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("video-note-\(UUID().uuidString).mov")
          self.outputURL = url
          self.startedAt = Date()
          self.cancelOnFinish = false
          self.isRecording = true
          self.isPreviewing = true
          if self.session?.isRunning != true {
            self.session?.startRunning()
          }
          movieOutput.startRecording(to: url, recordingDelegate: self)
          result(nil)
        } catch {
          self.cleanup(deleteFile: true)
          result(FlutterError(
            code: "video_note_start_failed",
            message: "Failed to start video note recording",
            details: error.localizedDescription
          ))
        }
      }
    }
  }

  private func startPreview(result: @escaping FlutterResult) {
    if isRecording {
      isPreviewing = true
      result(nil)
      return
    }

    if session?.isRunning == true {
      isPreviewing = true
      result(nil)
      return
    }

    requestCaptureAccess { [weak self] allowed in
      DispatchQueue.main.async {
        guard let self else { return }
        guard allowed else {
          result(FlutterError(
            code: "video_note_permission_denied",
            message: "Camera or microphone permission denied",
            details: nil
          ))
          return
        }

        do {
          try self.configureSession()
          self.isPreviewing = true
          self.session?.startRunning()
          result(nil)
        } catch {
          self.cleanup(deleteFile: true)
          result(FlutterError(
            code: "video_note_preview_failed",
            message: "Failed to start video note preview",
            details: error.localizedDescription
          ))
        }
      }
    }
  }

  private func stopPreview(result: @escaping FlutterResult) {
    isPreviewing = false
    guard !isRecording else {
      result(nil)
      return
    }
    cleanup(deleteFile: true)
    result(nil)
  }

  private func capturePhoto(result: @escaping FlutterResult) {
    guard let data = lastPreviewData, !data.isEmpty else {
      result(FlutterError(
        code: "video_note_photo_unavailable",
        message: "Camera preview frame is not ready",
        details: nil
      ))
      return
    }
    result(FlutterStandardTypedData(bytes: data))
  }

  private func stop(result: @escaping FlutterResult) {
    guard isRecording, let movieOutput else {
      result(FlutterError(
        code: "video_note_not_recording",
        message: "Video note recording is not active",
        details: nil
      ))
      return
    }
    pendingStopResult = result
    cancelOnFinish = false
    movieOutput.stopRecording()
  }

  private func cancel(result: @escaping FlutterResult) {
    guard isRecording, let movieOutput else {
      cleanup(deleteFile: true)
      result(nil)
      return
    }
    pendingStopResult = result
    cancelOnFinish = true
    movieOutput.stopRecording()
  }

  private func requestCaptureAccess(completion: @escaping (Bool) -> Void) {
    AVCaptureDevice.requestAccess(for: .video) { videoAllowed in
      guard videoAllowed else {
        completion(false)
        return
      }
      AVCaptureDevice.requestAccess(for: .audio) { audioAllowed in
        completion(audioAllowed)
      }
    }
  }

  private func configureSession() throws {
    cleanup(deleteFile: true)

    let nextSession = AVCaptureSession()
    nextSession.sessionPreset = .medium

    guard let videoDevice = preferredVideoDevice() else {
      throw NSError(domain: "project_fenix.video_note", code: 2)
    }
    guard let audioDevice = AVCaptureDevice.default(for: .audio) else {
      throw NSError(domain: "project_fenix.video_note", code: 3)
    }

    let videoInput = try AVCaptureDeviceInput(device: videoDevice)
    if nextSession.canAddInput(videoInput) {
      nextSession.addInput(videoInput)
    }

    let audioInput = try AVCaptureDeviceInput(device: audioDevice)
    if nextSession.canAddInput(audioInput) {
      nextSession.addInput(audioInput)
    }

    let nextOutput = AVCaptureMovieFileOutput()
    if nextSession.canAddOutput(nextOutput) {
      nextSession.addOutput(nextOutput)
    } else {
      throw NSError(domain: "project_fenix.video_note", code: 4)
    }

    let nextPreviewOutput = AVCaptureVideoDataOutput()
    nextPreviewOutput.alwaysDiscardsLateVideoFrames = true
    nextPreviewOutput.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    nextPreviewOutput.setSampleBufferDelegate(self, queue: previewQueue)
    if nextSession.canAddOutput(nextPreviewOutput) {
      nextSession.addOutput(nextPreviewOutput)
    }

    session = nextSession
    movieOutput = nextOutput
    previewOutput = nextPreviewOutput
    lastPreviewSentAt = 0
  }

  private func preferredVideoDevice() -> AVCaptureDevice? {
    let discovery = AVCaptureDevice.DiscoverySession(
      deviceTypes: [.builtInWideAngleCamera],
      mediaType: .video,
      position: .unspecified
    )
    return discovery.devices.first(where: { $0.position == .front })
      ?? discovery.devices.first
      ?? AVCaptureDevice.default(for: .video)
  }

  private func cleanup(deleteFile: Bool) {
    previewOutput?.setSampleBufferDelegate(nil, queue: nil)
    if session?.isRunning == true {
      session?.stopRunning()
    }
    if deleteFile, let outputURL {
      try? FileManager.default.removeItem(at: outputURL)
    }
    session = nil
    movieOutput = nil
    previewOutput = nil
    outputURL = nil
    startedAt = nil
    isRecording = false
    isPreviewing = false
    cancelOnFinish = false
    lastPreviewSentAt = 0
    lastPreviewData = nil
  }

  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard previewEventSink != nil else { return }
    let now = CACurrentMediaTime()
    guard now - lastPreviewSentAt >= 0.10 else { return }
    lastPreviewSentAt = now

    guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    let sourceImage = CIImage(cvPixelBuffer: imageBuffer)
    let extent = sourceImage.extent
    let side = min(extent.width, extent.height)
    guard side > 0 else { return }
    let cropRect = CGRect(
      x: extent.midX - side / 2,
      y: extent.midY - side / 2,
      width: side,
      height: side
    )
    let targetSide: CGFloat = 320
    let scale = targetSide / side
    let previewImage = sourceImage
      .cropped(to: cropRect)
      .transformed(by: CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y))
      .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let renderRect = CGRect(x: 0, y: 0, width: targetSide, height: targetSide)
    guard let cgImage = previewContext.createCGImage(previewImage, from: renderRect) else {
      return
    }
    let bitmap = NSBitmapImageRep(cgImage: cgImage)
    guard let data = bitmap.representation(
      using: .jpeg,
      properties: [.compressionFactor: 0.48]
    ) else {
      return
    }

    DispatchQueue.main.async { [weak self] in
      guard let self, self.isRecording || self.isPreviewing else { return }
      self.lastPreviewData = data
      self.previewEventSink?(FlutterStandardTypedData(bytes: data))
    }
  }

  func fileOutput(
    _ output: AVCaptureFileOutput,
    didFinishRecordingTo outputFileURL: URL,
    from connections: [AVCaptureConnection],
    error: Error?
  ) {
    let result = pendingStopResult
    pendingStopResult = nil

    if cancelOnFinish {
      cleanup(deleteFile: true)
      result?(nil)
      return
    }

    if let error {
      cleanup(deleteFile: true)
      result?(FlutterError(
        code: "video_note_recording_failed",
        message: "Video note recording failed",
        details: error.localizedDescription
      ))
      return
    }

    let durationMs = max(0, Int(Date().timeIntervalSince(startedAt ?? Date()) * 1000))
    let response: [String: Any] = [
      "path": outputFileURL.path,
      "filename": outputFileURL.lastPathComponent,
      "duration_ms": durationMs,
      "mime_type": "video/quicktime",
    ]
    cleanup(deleteFile: false)
    result?(response)
  }
}

private final class InputLanguageStreamHandler: NSObject, FlutterStreamHandler {
  private var eventSink: FlutterEventSink?
  private var pollTimer: Timer?
  private var lastCode: String?
  private let carbonNotificationName = Notification.Name(
    rawValue: kTISNotifySelectedKeyboardInputSourceChanged as String
  )
  private let appKitNotificationName = NSTextInputContext.keyboardSelectionDidChangeNotification

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    pushCurrentLanguageIfNeeded(force: true)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleInputSourceChange),
      name: appKitNotificationName,
      object: nil
    )
    DistributedNotificationCenter.default().addObserver(
      self,
      selector: #selector(handleInputSourceChange),
      name: carbonNotificationName,
      object: nil
    )
    startPolling()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    NotificationCenter.default.removeObserver(
      self,
      name: appKitNotificationName,
      object: nil
    )
    DistributedNotificationCenter.default().removeObserver(
      self,
      name: carbonNotificationName,
      object: nil
    )
    stopPolling()
    lastCode = nil
    return nil
  }

  @objc private func handleInputSourceChange(_ notification: Notification) {
    pushCurrentLanguageIfNeeded(force: true)
  }

  @objc private func pollCurrentLanguage() {
    pushCurrentLanguageIfNeeded(force: false)
  }

  private func pushCurrentLanguageIfNeeded(force: Bool) {
    let code = Self.currentLanguageCode()
    guard force || code != lastCode else { return }
    lastCode = code
    eventSink?(code)
  }

  private func startPolling() {
    stopPolling()
    pollTimer = Timer.scheduledTimer(
      timeInterval: 0.35,
      target: self,
      selector: #selector(pollCurrentLanguage),
      userInfo: nil,
      repeats: true
    )
    if let pollTimer {
      RunLoop.main.add(pollTimer, forMode: .common)
    }
  }

  private func stopPolling() {
    pollTimer?.invalidate()
    pollTimer = nil
  }

  static func currentLanguageCode() -> String {
    if let currentInputContext = NSTextInputContext.current,
       let selectedSourceId = currentInputContext.selectedKeyboardInputSource,
       let code = normalizedCodeFromInputSource(identifier: selectedSourceId) {
      return code
    }

    guard let inputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
      return fallbackCode()
    }

    if let rawLanguages = TISGetInputSourceProperty(inputSource, kTISPropertyInputSourceLanguages) {
      let languages = Unmanaged<CFArray>.fromOpaque(rawLanguages).takeUnretainedValue() as NSArray
      if let first = languages.firstObject as? String {
        return normalizedCode(first)
      }
    }

    if let sourceIdPointer = TISGetInputSourceProperty(inputSource, kTISPropertyInputSourceID) {
      let sourceId = Unmanaged<CFString>.fromOpaque(sourceIdPointer).takeUnretainedValue() as String
      if let code = normalizedCodeFromInputSource(identifier: sourceId) {
        return code
      }
    }

    return fallbackCode()
  }

  private static func fallbackCode() -> String {
    return normalizedCode(Locale.current.languageCode ?? "en")
  }

  private static func normalizedCodeFromInputSource(identifier: String) -> String? {
    let normalizedIdentifier = identifier.lowercased()
    if normalizedIdentifier.isEmpty {
      return nil
    }

    let directMappings: [(String, String)] = [
      ("russian", "RU"),
      ("ukrainian", "UK"),
      ("belarusian", "BE"),
      ("armenian", "HY"),
      ("georgian", "KA"),
      ("hebrew", "HE"),
      ("arabic", "AR"),
      ("greek", "EL"),
      ("bulgarian", "BG"),
      ("kazakh", "KK"),
      ("japanese", "JA"),
      ("korean", "KO"),
      ("pinyin", "ZH"),
      ("zhuyin", "ZH"),
      ("simplified", "ZH"),
      ("traditional", "ZH"),
      ("spanish", "ES"),
      ("french", "FR"),
      ("german", "DE"),
      ("italian", "IT"),
      ("turkish", "TR"),
      ("polish", "PL"),
      ("portuguese", "PT"),
      ("abc", "EN"),
      ("u.s", "EN"),
      ("us", "EN"),
      ("british", "EN"),
      ("english", "EN"),
    ]

    for (needle, code) in directMappings where normalizedIdentifier.contains(needle) {
      return code
    }

    let components = identifier
      .split(separator: ".")
      .map { String($0) }
      .filter { !$0.isEmpty }

    for component in components.reversed() {
      let code = normalizedCode(component)
      if code.count == 2 || code.count == 3 {
        return code
      }
    }

    return nil
  }

  private static func normalizedCode(_ raw: String) -> String {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return "EN" }
    let separators = CharacterSet(charactersIn: "-_")
    let code = value.components(separatedBy: separators).first ?? value
    return code.uppercased()
  }
}
