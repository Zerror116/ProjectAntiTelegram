import '../main.dart';

class MessengerPreferences {
  const MessengerPreferences({
    required this.mediaAutoDownloadImages,
    required this.mediaAutoDownloadAudio,
    required this.mediaAutoDownloadVideo,
    required this.mediaAutoDownloadDocuments,
    required this.mediaSendQualityWifi,
    required this.mediaSendQualityCellular,
  });

  final String mediaAutoDownloadImages;
  final String mediaAutoDownloadAudio;
  final String mediaAutoDownloadVideo;
  final String mediaAutoDownloadDocuments;
  final String mediaSendQualityWifi;
  final String mediaSendQualityCellular;

  static const MessengerPreferences defaults = MessengerPreferences(
    mediaAutoDownloadImages: 'wifi_cellular',
    mediaAutoDownloadAudio: 'wifi_cellular',
    mediaAutoDownloadVideo: 'wifi',
    mediaAutoDownloadDocuments: 'wifi',
    mediaSendQualityWifi: 'hd',
    mediaSendQualityCellular: 'standard',
  );

  factory MessengerPreferences.fromMap(Map<String, dynamic> map) {
    String normalizeAuto(dynamic raw, String fallback) {
      final value = (raw ?? '').toString().trim().toLowerCase();
      switch (value) {
        case 'never':
        case 'wifi':
        case 'wifi_cellular':
          return value;
        default:
          return fallback;
      }
    }

    String normalizeQuality(dynamic raw, String fallback) {
      final value = (raw ?? '').toString().trim().toLowerCase();
      switch (value) {
        case 'standard':
        case 'hd':
        case 'file':
          return value;
        default:
          return fallback;
      }
    }

    return MessengerPreferences(
      mediaAutoDownloadImages: normalizeAuto(
        map['media_auto_download_images'],
        defaults.mediaAutoDownloadImages,
      ),
      mediaAutoDownloadAudio: normalizeAuto(
        map['media_auto_download_audio'],
        defaults.mediaAutoDownloadAudio,
      ),
      mediaAutoDownloadVideo: normalizeAuto(
        map['media_auto_download_video'],
        defaults.mediaAutoDownloadVideo,
      ),
      mediaAutoDownloadDocuments: normalizeAuto(
        map['media_auto_download_documents'],
        defaults.mediaAutoDownloadDocuments,
      ),
      mediaSendQualityWifi: normalizeQuality(
        map['media_send_quality_wifi'],
        defaults.mediaSendQualityWifi,
      ),
      mediaSendQualityCellular: normalizeQuality(
        map['media_send_quality_cellular'],
        defaults.mediaSendQualityCellular,
      ),
    );
  }

  Map<String, dynamic> toPatchMap() {
    return <String, dynamic>{
      'media_auto_download_images': mediaAutoDownloadImages,
      'media_auto_download_audio': mediaAutoDownloadAudio,
      'media_auto_download_video': mediaAutoDownloadVideo,
      'media_auto_download_documents': mediaAutoDownloadDocuments,
      'media_send_quality_wifi': mediaSendQualityWifi,
      'media_send_quality_cellular': mediaSendQualityCellular,
    };
  }

  MessengerPreferences copyWith({
    String? mediaAutoDownloadImages,
    String? mediaAutoDownloadAudio,
    String? mediaAutoDownloadVideo,
    String? mediaAutoDownloadDocuments,
    String? mediaSendQualityWifi,
    String? mediaSendQualityCellular,
  }) {
    return MessengerPreferences(
      mediaAutoDownloadImages:
          mediaAutoDownloadImages ?? this.mediaAutoDownloadImages,
      mediaAutoDownloadAudio:
          mediaAutoDownloadAudio ?? this.mediaAutoDownloadAudio,
      mediaAutoDownloadVideo:
          mediaAutoDownloadVideo ?? this.mediaAutoDownloadVideo,
      mediaAutoDownloadDocuments:
          mediaAutoDownloadDocuments ?? this.mediaAutoDownloadDocuments,
      mediaSendQualityWifi:
          mediaSendQualityWifi ?? this.mediaSendQualityWifi,
      mediaSendQualityCellular:
          mediaSendQualityCellular ?? this.mediaSendQualityCellular,
    );
  }
}

class MessengerPreferencesService {
  const MessengerPreferencesService();

  Future<MessengerPreferences> load() async {
    final resp = await authService.dio.get('/api/messenger/preferences');
    final data = resp.data;
    if (data is Map && data['ok'] == true && data['data'] is Map) {
      return MessengerPreferences.fromMap(
        Map<String, dynamic>.from(data['data'] as Map),
      );
    }
    return MessengerPreferences.defaults;
  }

  Future<MessengerPreferences> save(MessengerPreferences prefs) async {
    final resp = await authService.dio.patch(
      '/api/messenger/preferences',
      data: prefs.toPatchMap(),
    );
    final data = resp.data;
    if (data is Map && data['ok'] == true && data['data'] is Map) {
      return MessengerPreferences.fromMap(
        Map<String, dynamic>.from(data['data'] as Map),
      );
    }
    return prefs;
  }
}

const messengerPreferencesService = MessengerPreferencesService();
