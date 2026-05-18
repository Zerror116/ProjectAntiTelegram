import 'package:flutter/foundation.dart';

import 'current_user_agent.dart';

class ChatCaptureProfile {
  const ChatCaptureProfile({
    required this.platformKey,
    required this.cameraSupported,
    required this.videoNoteCaptureSupported,
    required this.videoNoteFallbackReason,
  });

  final String platformKey;
  final bool cameraSupported;
  final bool videoNoteCaptureSupported;
  final String videoNoteFallbackReason;
}

class ChatCaptureCapabilityService {
  const ChatCaptureCapabilityService._();

  static ChatCaptureProfile get current {
    if (!kIsWeb) {
      switch (defaultTargetPlatform) {
        case TargetPlatform.android:
          return const ChatCaptureProfile(
            platformKey: 'android',
            cameraSupported: true,
            videoNoteCaptureSupported: true,
            videoNoteFallbackReason: '',
          );
        case TargetPlatform.iOS:
          return const ChatCaptureProfile(
            platformKey: 'ios',
            cameraSupported: true,
            videoNoteCaptureSupported: true,
            videoNoteFallbackReason: '',
          );
        case TargetPlatform.macOS:
          return const ChatCaptureProfile(
            platformKey: 'macos',
            cameraSupported: true,
            videoNoteCaptureSupported: true,
            videoNoteFallbackReason: '',
          );
        case TargetPlatform.windows:
          return const ChatCaptureProfile(
            platformKey: 'windows',
            cameraSupported: false,
            videoNoteCaptureSupported: false,
            videoNoteFallbackReason:
                'Видеокружки в Windows-приложении пока недоступны. Используйте веб-версию или отправку обычного видео.',
          );
        case TargetPlatform.linux:
          return const ChatCaptureProfile(
            platformKey: 'linux',
            cameraSupported: false,
            videoNoteCaptureSupported: false,
            videoNoteFallbackReason:
                'Видеокружки в Linux-приложении пока недоступны. Используйте веб-версию или отправку обычного видео.',
          );
        case TargetPlatform.fuchsia:
          return const ChatCaptureProfile(
            platformKey: 'fuchsia',
            cameraSupported: false,
            videoNoteCaptureSupported: false,
            videoNoteFallbackReason:
                'Видеокружки на этой платформе пока недоступны. Используйте веб-версию или отправку обычного видео.',
          );
      }
    }

    final agent = currentUserAgent().toLowerCase();
    final isIosWeb =
        agent.contains('iphone') ||
        agent.contains('ipad') ||
        agent.contains('ipod') ||
        (defaultTargetPlatform == TargetPlatform.iOS);
    final isFirefox = agent.contains('firefox') || agent.contains('fxios');
    final isChromium =
        agent.contains('chrome') ||
        agent.contains('chromium') ||
        agent.contains('crios') ||
        agent.contains('edg') ||
        agent.contains('opr/') ||
        agent.contains('opera');
    final isSafari =
        agent.contains('safari') && !isChromium && !agent.contains('android');

    if (isIosWeb) {
      return const ChatCaptureProfile(
        platformKey: 'web_ios',
        cameraSupported: true,
        videoNoteCaptureSupported: true,
        videoNoteFallbackReason: '',
      );
    }

    if (isSafari) {
      return const ChatCaptureProfile(
        platformKey: 'web_safari',
        cameraSupported: true,
        videoNoteCaptureSupported: true,
        videoNoteFallbackReason: '',
      );
    }

    if (isFirefox) {
      return const ChatCaptureProfile(
        platformKey: 'web_firefox',
        cameraSupported: true,
        videoNoteCaptureSupported: true,
        videoNoteFallbackReason: '',
      );
    }

    if (isChromium) {
      return const ChatCaptureProfile(
        platformKey: 'web_chromium',
        cameraSupported: true,
        videoNoteCaptureSupported: true,
        videoNoteFallbackReason: '',
      );
    }

    return const ChatCaptureProfile(
      platformKey: 'web_unknown',
      cameraSupported: true,
      videoNoteCaptureSupported: true,
      videoNoteFallbackReason: '',
    );
  }
}
