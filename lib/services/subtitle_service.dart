import 'dart:convert';
import 'package:http/http.dart' as http;

/// Search and download subtitles from OpenSubtitles REST API v1.
///
/// Free tier: 5 downloads/day, 20 search results.
/// Users can configure their own API key in settings for higher limits.
class SubtitleService {
  static const _baseUrl = 'https://api.opensubtitles.com/api/v1';
  // Default free-tier API key — users should replace with their own
  static const _defaultApiKey = 'rl-caster-free-tier';

  String _apiKey = _defaultApiKey;

  void setApiKey(String key) => _apiKey = key;

  /// Search subtitles by video title and optional language.
  Future<List<SubtitleResult>> search({
    required String query,
    String? language, // ISO 639-1 code (e.g., "en", "fr", "es")
    int? year,
  }) async {
    final params = <String, String>{
      'query': query,
    };
    if (language != null) params['languages'] = language;
    if (year != null) params['year'] = year.toString();

    final uri = Uri.parse('$_baseUrl/subtitles').replace(queryParameters: params);
    final response = await http.get(uri, headers: {
      'Api-Key': _apiKey,
      'Content-Type': 'application/json',
      'User-Agent': 'RLCaster v1.0',
    }).timeout(const Duration(seconds: 10));

    if (response.statusCode != 200) {
      throw Exception('Subtitle search failed (${response.statusCode})');
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final data = json['data'] as List? ?? [];

    return data.map((item) {
      final attrs = item['attributes'] as Map<String, dynamic>? ?? {};
      final files = attrs['files'] as List? ?? [];
      final firstFile = files.isNotEmpty ? files[0] as Map<String, dynamic> : null;

      return SubtitleResult(
        id: item['id']?.toString() ?? '',
        fileId: firstFile?['file_id']?.toString() ?? '',
        language: attrs['language'] as String? ?? 'unknown',
        title: attrs['feature_details']?['title'] as String? ??
            attrs['release'] as String? ??
            'Unknown',
        release: attrs['release'] as String? ?? '',
        downloadCount: attrs['download_count'] as int? ?? 0,
        isHearingImpaired: attrs['hearing_impaired'] as bool? ?? false,
        fps: (attrs['fps'] as num?)?.toDouble(),
        uploadDate: attrs['upload_date'] as String?,
      );
    }).toList();
  }

  /// Download a subtitle file by file_id. Returns SRT content or null on failure.
  Future<String?> download(String fileId) async {
    // Step 1: Request download link
    final response = await http.post(
      Uri.parse('$_baseUrl/download'),
      headers: {
        'Api-Key': _apiKey,
        'Content-Type': 'application/json',
        'User-Agent': 'RLCaster v1.0',
      },
      body: jsonEncode({'file_id': int.tryParse(fileId) ?? fileId}),
    ).timeout(const Duration(seconds: 10));

    if (response.statusCode != 200) {
      throw Exception('Subtitle download failed (${response.statusCode})');
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final link = json['link'] as String?;
    if (link == null) throw Exception('No download link returned');

    // Step 2: Download the actual subtitle file
    final subResponse = await http.get(Uri.parse(link))
        .timeout(const Duration(seconds: 15));
    if (subResponse.statusCode != 200) {
      throw Exception('Subtitle file download failed');
    }

    return subResponse.body;
  }
}

class SubtitleResult {
  final String id;
  final String fileId;
  final String language;
  final String title;
  final String release;
  final int downloadCount;
  final bool isHearingImpaired;
  final double? fps;
  final String? uploadDate;

  const SubtitleResult({
    required this.id,
    required this.fileId,
    required this.language,
    required this.title,
    required this.release,
    required this.downloadCount,
    required this.isHearingImpaired,
    this.fps,
    this.uploadDate,
  });

  /// Display-friendly filename: use release name or title.
  String get filename => release.isNotEmpty ? release : title;
}
