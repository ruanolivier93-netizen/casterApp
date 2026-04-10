import 'dart:convert';
import 'package:http/http.dart' as http;

/// Search and download subtitles from OpenSubtitles REST API v1.
///
/// Requires a valid API key from https://www.opensubtitles.com/en/consumers
/// Free tier: 5 downloads/day, unlimited searches.
class SubtitleService {
  static const _baseUrl = 'https://api.opensubtitles.com/api/v1';

  String _apiKey = '';

  void setApiKey(String key) => _apiKey = key.trim();

  bool get hasApiKey => _apiKey.isNotEmpty;

  /// Clean a video title for better search results.
  /// Strips common noise like "Watch", "Online", "HD", site names, years in
  /// parentheses at the end, trailing quality markers, etc.
  static String cleanTitle(String raw) {
    var t = raw;
    // Remove common prefixes/suffixes added by streaming sites
    t = t.replaceAll(RegExp(
        r'\b(watch|online|free|full\s*movie|full\s*episode|streaming|stream'
        r'|hd|hdtv|720p|1080p|2160p|4k|uhd|bluray|blu[\-\s]?ray|webrip'
        r'|web[\-\s]?dl|dvdrip|brrip|x264|x265|hevc|aac|mkv|mp4)\b',
        caseSensitive: false), '');
    // Remove site names like " - SiteName" or "| SiteName" at the end
    t = t.replaceAll(RegExp(r'[\|\-–—]\s*[A-Za-z0-9]+\.[a-z]{2,4}\s*$'), '');
    // Remove trailing year in parentheses: "Movie (2024)"
    final yearMatch = RegExp(r'\((\d{4})\)\s*$').firstMatch(t);
    if (yearMatch != null) {
      t = t.substring(0, yearMatch.start);
    }
    // Remove S01E01 style markers
    t = t.replaceAll(RegExp(r'S\d{1,2}E\d{1,2}', caseSensitive: false), '');
    // Collapse whitespace
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    // Remove trailing/leading punctuation
    t = t.replaceAll(RegExp(r'^[\s\-–—:.|]+|[\s\-–—:.|]+$'), '').trim();
    return t;
  }

  /// Try to extract a 4-digit year from a title string.
  static int? extractYear(String title) {
    final m = RegExp(r'[\(\[]?(\d{4})[\)\]]?').firstMatch(title);
    if (m != null) {
      final y = int.parse(m.group(1)!);
      if (y >= 1900 && y <= 2030) return y;
    }
    return null;
  }

  /// Search subtitles by video title and optional language.
  Future<List<SubtitleResult>> search({
    required String query,
    String? language, // ISO 639-1 code (e.g., "en", "fr", "es")
    int? year,
  }) async {
    if (!hasApiKey) {
      throw SubtitleApiKeyMissing();
    }

    final cleaned = cleanTitle(query);
    final extractedYear = year ?? extractYear(query);

    final params = <String, String>{
      'query': cleaned,
    };
    if (language != null) params['languages'] = language;
    if (extractedYear != null) params['year'] = extractedYear.toString();

    final uri =
        Uri.parse('$_baseUrl/subtitles').replace(queryParameters: params);
    final http.Response response;
    try {
      response = await http.get(uri, headers: {
        'Api-Key': _apiKey,
        'Content-Type': 'application/json',
        'User-Agent': 'RLCaster v1.0',
      }).timeout(const Duration(seconds: 10));
    } catch (e) {
      throw Exception('Network error searching subtitles: $e');
    }

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw SubtitleApiKeyInvalid();
    }
    if (response.statusCode == 429) {
      throw Exception(
        'OpenSubtitles rate limit reached. Please wait a minute and try again.',
      );
    }
    if (response.statusCode != 200) {
      throw Exception('Subtitle search failed (HTTP ${response.statusCode})');
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final data = json['data'] as List? ?? [];

    if (data.isEmpty && cleaned != query) {
      // Retry with raw query if cleaned version returned nothing
      return _searchRaw(query: query, language: language);
    }

    return _parseResults(data);
  }

  /// Fallback search with the unmodified query string.
  Future<List<SubtitleResult>> _searchRaw({
    required String query,
    String? language,
  }) async {
    final params = <String, String>{'query': query};
    if (language != null) params['languages'] = language;

    final uri =
        Uri.parse('$_baseUrl/subtitles').replace(queryParameters: params);
    final response = await http.get(uri, headers: {
      'Api-Key': _apiKey,
      'Content-Type': 'application/json',
      'User-Agent': 'RLCaster v1.0',
    }).timeout(const Duration(seconds: 10));

    if (response.statusCode != 200) return [];

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return _parseResults(json['data'] as List? ?? []);
  }

  List<SubtitleResult> _parseResults(List<dynamic> data) {
    return data.map((item) {
      final attrs = item['attributes'] as Map<String, dynamic>? ?? {};
      final files = attrs['files'] as List? ?? [];
      final firstFile =
          files.isNotEmpty ? files[0] as Map<String, dynamic> : null;

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
    if (!hasApiKey) throw SubtitleApiKeyMissing();

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

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw SubtitleApiKeyInvalid();
    }
    if (response.statusCode == 429) {
      throw Exception(
        'OpenSubtitles download limit reached. Free tier allows 5 downloads/day.',
      );
    }
    if (response.statusCode != 200) {
      throw Exception('Subtitle download failed (HTTP ${response.statusCode})');
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final link = json['link'] as String?;
    if (link == null) throw Exception('No download link returned');

    // Step 2: Download the actual subtitle file
    final subResponse =
        await http.get(Uri.parse(link)).timeout(const Duration(seconds: 15));
    if (subResponse.statusCode != 200) {
      throw Exception('Subtitle file download failed');
    }

    return subResponse.body;
  }
}

/// Thrown when no API key has been configured.
class SubtitleApiKeyMissing implements Exception {
  @override
  String toString() => 'No OpenSubtitles API key configured. '
      'Get a free key at opensubtitles.com/consumers and add it in Settings.';
}

/// Thrown when the configured API key is rejected by the server.
class SubtitleApiKeyInvalid implements Exception {
  @override
  String toString() => 'OpenSubtitles API key is invalid. '
      'Check your key in Settings or get a new one at opensubtitles.com/consumers.';
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
