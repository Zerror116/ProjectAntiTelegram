import Cocoa
import FlutterMacOS
import Carbon.HIToolbox

@main
class AppDelegate: FlutterAppDelegate {
  private let inputLanguageStreamHandler = InputLanguageStreamHandler()
  private var inputLanguageChannelConfigured = false

  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    configureInputLanguageChannels()
    DispatchQueue.main.async { [weak self] in
      self?.configureInputLanguageChannels()
    }
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

    inputLanguageChannelConfigured = true
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
