import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Runs a local HTTP server that proxies the video stream to the TV.
/// When "route through phone" is ON, the TV fetches from this server
/// and the phone fetches from the real source — handling auth headers,
/// geo-restrictions, and URLs the TV can't resolve itself.
///
/// Also serves local device files (file:// URLs) over HTTP so TVs can play them.
class StreamProxyService {
  HttpServer? _server;
  String? _streamUrl;
  Map<String, String> _extraHeaders = {};
  String? _subtitleSrt; // SRT content served at /subtitle.srt
  String? _originalMimeType; // MIME type derived from the original URL

  // Persistent client for connection pooling — avoids TCP handshake overhead
  // per chunk and keeps connections alive for large streams.
  final _client = http.Client();

  bool get isRunning => _server != null;

  /// The MIME type of the original stream (before proxying).
  /// Used to build correct DLNA DIDL metadata.
  String? get originalMimeType => _originalMimeType;

  /// Returns the base URL for the proxy (e.g. http://192.168.1.5:12345).
  /// Stream is at /stream, subtitles at /subtitle.srt.
  Future<String?> start({
    required String streamUrl,
    Map<String, String> extraHeaders = const {},
    String? subtitleSrt,
  }) async {
    await stop();

    _streamUrl = streamUrl;
    _extraHeaders = Map.of(extraHeaders);
    _subtitleSrt = subtitleSrt;
    _originalMimeType = _guessMime(streamUrl);

    final ip = await _localIP();
    if (ip == null) return null;

    // Port 0 = OS assigns an available port automatically.
    // This eliminates the hardcoded-port-9876 collision bug.
    _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    final port = _server!.port;
    _serve();
    return 'http://$ip:$port';
  }

  /// The stream URL the TV should fetch.
  String? get streamEndpoint =>
      _server == null ? null : 'http://${_server!.address.host}:${_server!.port}/stream';

  /// The subtitle URL the TV should fetch (null if no subs loaded).
  String? get subtitleEndpoint => _subtitleSrt != null && _server != null
      ? 'http://${_server!.address.host}:${_server!.port}/subtitle.srt'
      : null;

  void _serve() {
    _server?.listen((req) async {
      final path = req.uri.path;

      // ── CORS preflight ─────────────────────────────────────────────────
      if (req.method == 'OPTIONS') {
        req.response
          ..statusCode = 204
          ..headers.set('Access-Control-Allow-Origin', '*')
          ..headers.set('Access-Control-Allow-Methods', 'GET, HEAD, OPTIONS')
          ..headers.set('Access-Control-Allow-Headers', 'Range')
          ..headers.set('Access-Control-Max-Age', '86400');
        await req.response.close();
        return;
      }

      // ── Subtitle endpoint ──────────────────────────────────────────────
      if (path == '/subtitle.srt' && _subtitleSrt != null) {
        req.response
          ..statusCode = 200
          ..headers.set('Content-Type', 'application/x-subrip; charset=utf-8')
          ..headers.set('Access-Control-Allow-Origin', '*')
          ..write(_subtitleSrt);
        await req.response.close();
        return;
      }

      // ── Stream proxy endpoint ──────────────────────────────────────────
      final streamUrl = _streamUrl;
      if (streamUrl == null || path != '/stream') {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }

      // ── Local file serving ─────────────────────────────────────────────
      if (streamUrl.startsWith('file://') || streamUrl.startsWith('/')) {
        await _serveLocalFile(req, streamUrl);
        return;
      }

      // ── Remote stream proxy ────────────────────────────────────────────
      await _proxyRemoteStream(req, streamUrl);
    }, onError: (_) {}); // Don't let individual request errors kill the server
  }

  /// Serves a local file with full Range/seek support.
  Future<void> _serveLocalFile(HttpRequest req, String fileUrl) async {
    try {
      final filePath = fileUrl.startsWith('file://')
          ? Uri.parse(fileUrl).toFilePath()
          : fileUrl;
      final file = File(filePath);
      if (!await file.exists()) {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }

      final fileLength = await file.length();
      final mime = _guessMime(filePath);

      // Handle Range requests for seeking
      final range = req.headers.value('range');
      int start = 0;
      int end = fileLength - 1;

      if (range != null) {
        final match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range);
        if (match != null) {
          start = int.parse(match.group(1)!);
          if (match.group(2)!.isNotEmpty) {
            end = int.parse(match.group(2)!);
          }
        }
        // Return 416 if the requested range is unsatisfiable.
        if (start >= fileLength) {
          req.response.statusCode = 416;
          req.response.headers.set('Content-Range', 'bytes */$fileLength');
          await req.response.close();
          return;
        }
        end = end.clamp(start, fileLength - 1);
        req.response.statusCode = 206;
        req.response.headers.set('Content-Range', 'bytes $start-$end/$fileLength');
      } else {
        req.response.statusCode = 200;
      }

      req.response.headers.set('Content-Type', mime);
      req.response.headers.set('Content-Length', '${end - start + 1}');
      req.response.headers.set('Accept-Ranges', 'bytes');
      req.response.headers.set('Access-Control-Allow-Origin', '*');

      if (req.method == 'HEAD') {
        await req.response.close();
        return;
      }

      final stream = file.openRead(start, end + 1);
      await req.response.addStream(stream);
      await req.response.close();
    } catch (_) {
      try {
        req.response.statusCode = 500;
        await req.response.close();
      } catch (_) {}
    }
  }

  /// Proxies a remote HTTP stream to the local TV.
  Future<void> _proxyRemoteStream(HttpRequest req, String streamUrl) async {
    try {
      final parsedUrl = Uri.parse(streamUrl);

      // Use a platform-appropriate User-Agent so CDNs don't reject requests.
      final ua = defaultTargetPlatform == TargetPlatform.iOS
          ? 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
              'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1'
          : 'Mozilla/5.0 (Linux; Android 14; Pixel 8) '
              'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';

      final headers = <String, String>{
        'User-Agent': ua,
        'Accept': '*/*',
        'Accept-Language': 'en-US,en;q=0.9',
        'Connection': 'keep-alive',
        // Origin and Referer are required by many CDNs and YouTube to allow
        // cross-origin requests; without them the server returns 403.
        'Origin': '${parsedUrl.scheme}://${parsedUrl.host}',
        'Referer': '${parsedUrl.scheme}://${parsedUrl.host}/',
        ..._extraHeaders,
      };

      // Forward Range header so the TV can seek within the stream.
      final range = req.headers.value('range');
      if (range != null) headers['Range'] = range;

      final upstreamReq = http.Request('GET', Uri.parse(streamUrl))
        ..headers.addAll(headers);

      final upstreamResp = await _client.send(upstreamReq)
          .timeout(const Duration(seconds: 30));

      req.response.statusCode = upstreamResp.statusCode;

      for (final entry in upstreamResp.headers.entries) {
        switch (entry.key.toLowerCase()) {
          case 'content-type':
          case 'content-length':
          case 'content-range':
          case 'accept-ranges':
          case 'cache-control':
          case 'transfer-encoding':
            req.response.headers.set(entry.key, entry.value);
        }
      }
      // Always advertise range support so the TV knows it can seek.
      if (!upstreamResp.headers.containsKey('accept-ranges')) {
        req.response.headers.set('accept-ranges', 'bytes');
      }
      // Guarantee a Content-Type — some TVs refuse playback without one.
      if (!upstreamResp.headers.containsKey('content-type')) {
        req.response.headers.set('content-type', _guessMime(streamUrl));
      }
      // CORS — allows any embedded player to read the stream.
      req.response.headers.set('Access-Control-Allow-Origin', '*');

      await req.response.addStream(upstreamResp.stream);
      await req.response.close();
    } on TimeoutException catch (_) {
      try {
        req.response.statusCode = 504;
        await req.response.close();
      } catch (_) {}
    } catch (_) {
      try {
        req.response.statusCode = 502;
        await req.response.close();
      } catch (_) {}
    }
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _streamUrl = null;
    _extraHeaders = {};
    _subtitleSrt = null;
    _originalMimeType = null;
  }

  /// Best-guess MIME type from file extension when upstream omits Content-Type.
  static String _guessMime(String url) {
    final lower = url.toLowerCase().split('?').first;
    // Video
    if (lower.endsWith('.mp4') || lower.endsWith('.m4v')) return 'video/mp4';
    if (lower.endsWith('.webm')) return 'video/webm';
    if (lower.endsWith('.mkv')) return 'video/x-matroska';
    if (lower.endsWith('.avi')) return 'video/x-msvideo';
    if (lower.endsWith('.mov') || lower.endsWith('.qt')) return 'video/quicktime';
    if (lower.endsWith('.ts')) return 'video/mp2t';
    if (lower.endsWith('.flv')) return 'video/x-flv';
    if (lower.endsWith('.3gp')) return 'video/3gpp';
    if (lower.contains('.m3u8')) return 'application/x-mpegURL';
    if (lower.endsWith('.mpd')) return 'application/dash+xml';
    // Audio
    if (lower.endsWith('.mp3')) return 'audio/mpeg';
    if (lower.endsWith('.aac') || lower.endsWith('.m4a')) return 'audio/mp4';
    if (lower.endsWith('.flac')) return 'audio/flac';
    if (lower.endsWith('.ogg') || lower.endsWith('.oga')) return 'audio/ogg';
    if (lower.endsWith('.wav')) return 'audio/wav';
    if (lower.endsWith('.wma')) return 'audio/x-ms-wma';
    if (lower.endsWith('.opus')) return 'audio/opus';
    return 'video/mp4'; // safe fallback
  }

  Future<String?> _localIP() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      // Prefer well-known WiFi interface names first.
      for (final iface in interfaces) {
        final n = iface.name.toLowerCase();
        if ((n.contains('wlan') ||
                n.contains('en0') ||
                n.contains('en1') ||
                n.contains('wi-fi')) &&
            iface.addresses.isNotEmpty) {
          return iface.addresses.first.address;
        }
      }
      // Fallback: first non-loopback, non-link-local (169.254.x.x) IPv4.
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.address.startsWith('169.254.')) return addr.address;
        }
      }
    } catch (_) {}
    return null;
  }

  void dispose() => _client.close();
}
