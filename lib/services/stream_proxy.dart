import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Runs a local HTTP server that proxies the video stream to the TV.
/// When "route through phone" is ON, the TV fetches from this server
/// and the phone fetches from the real source — handling auth headers,
/// geo-restrictions, and URLs the TV can't resolve itself.
///
/// Also serves local device files (file:// URLs) over HTTP so TVs can play them.
///
/// For HLS streams, the proxy rewrites manifest URLs so the TV fetches every
/// segment through this server instead of hitting the CDN directly (which
/// would fail without auth headers / cookies the TV doesn't have).
class StreamProxyService {
  HttpServer? _server;
  String? _streamUrl;
  String? _baseUrl; // e.g. http://192.168.1.5:12345
  String? _originHost; // Origin/Referer host for all proxied requests
  Map<String, String> _extraHeaders = {};
  String? _subtitleSrt; // SRT content served at /subtitle.srt
  String? _originalMimeType; // MIME type derived from the original URL

  // Fresh client per proxy session — avoids stale pooled connections from
  // previous casts that can cause immediate "connection lost" on the TV.
  http.Client? _client;

  bool get isRunning => _server != null;

  /// The MIME type of the original stream (before proxying).
  /// Used to build correct DLNA DIDL metadata.
  String? get originalMimeType => _originalMimeType;

  /// Returns the base URL for the proxy (e.g. http://192.168.1.5:12345).
  /// Stream is at /stream, subtitles at /subtitle.srt.
  ///
  /// [refererUrl] — optional page URL the video was found on.  Used as
  /// Origin/Referer for upstream requests so CDNs see the correct domain.
  Future<String?> start({
    required String streamUrl,
    Map<String, String> extraHeaders = const {},
    String? subtitleSrt,
    String? refererUrl,
  }) async {
    await stop();

    _streamUrl = streamUrl;
    _extraHeaders = Map.of(extraHeaders);
    _subtitleSrt = subtitleSrt;
    _originalMimeType = _guessMime(streamUrl);

    // Create a fresh HTTP client for each proxy session so we don't carry
    // stale connections from a previous cast that might cause the TV to
    // get "connection lost" immediately.
    _client?.close();
    _client = http.Client();

    // Remember the origin host — used as Origin/Referer for all proxied
    // requests (CDNs often require the original page domain, not whatever
    // CDN sub-domain a segment happens to be hosted on).
    // Prefer the explicit page referer over the stream URL's host.
    final refHost = refererUrl != null ? Uri.tryParse(refererUrl) : null;
    final strHost = Uri.tryParse(streamUrl);
    if (refHost != null && refHost.host.isNotEmpty) {
      _originHost = '${refHost.scheme}://${refHost.host}';
    } else if (strHost != null && strHost.host.isNotEmpty) {
      _originHost = '${strHost.scheme}://${strHost.host}';
    }

    final ip = await _localIP();
    if (ip == null) return null;

    // Port 0 = OS assigns an available port automatically.
    // This eliminates the hardcoded-port-9876 collision bug.
    _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    final port = _server!.port;
    _baseUrl = 'http://$ip:$port';
    _serve();
    return _baseUrl;
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
          ..headers.set('Access-Control-Allow-Headers', 'Range, Content-Type')
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

      // ── Proxy endpoint — proxies arbitrary URLs (used for HLS segments,
      //    variant playlists, encryption keys, etc.) ──────────────────────
      if (path == '/proxy') {
        final proxyUrl = req.uri.queryParameters['url'];
        if (proxyUrl == null || proxyUrl.isEmpty) {
          req.response.statusCode = 400;
          await req.response.close();
          return;
        }
        await _proxyRemoteStream(req, proxyUrl);
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
  /// If the response is an HLS manifest (.m3u8), segment/variant URLs are
  /// rewritten to go through this proxy so the TV never contacts the CDN
  /// directly (which would fail without proper headers/cookies).
  ///
  /// Implements **auto-resume**: many CDNs (YouTube, lookmovie, etc.) throttle
  /// connections by sending an initial burst of data (~7-10 seconds) and then
  /// closing the connection, expecting the client to reconnect with a Range
  /// header for the next chunk.  We detect this and keep reconnecting until
  /// all data is delivered to the TV.
  Future<void> _proxyRemoteStream(HttpRequest req, String streamUrl) async {
    try {
      final parsedUrl = Uri.parse(streamUrl);
      final isHead = req.method == 'HEAD';

      // Use a platform-appropriate User-Agent so CDNs don't reject requests.
      final ua = defaultTargetPlatform == TargetPlatform.iOS
          ? 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
              'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1'
          : 'Mozilla/5.0 (Linux; Android 14; Pixel 8) '
              'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';

      final baseHeaders = <String, String>{
        'User-Agent': ua,
        'Accept': '*/*',
        'Accept-Language': 'en-US,en;q=0.9',
        'Connection': 'keep-alive',
        'Origin': _originHost ?? '${parsedUrl.scheme}://${parsedUrl.host}',
        'Referer': _originHost != null ? '$_originHost/' : '${parsedUrl.scheme}://${parsedUrl.host}/',
        ..._extraHeaders,
      };

      // Forward Range header so the TV can seek within the stream.
      final tvRange = req.headers.value('range');
      if (tvRange != null) baseHeaders['Range'] = tvRange;

      // ── Initial upstream fetch (with retry) ────────────────────────────
      final method = isHead ? 'HEAD' : 'GET';
      http.StreamedResponse? upstreamResp;
      Object? lastError;
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          final upstreamReq = http.Request(method, Uri.parse(streamUrl))
            ..headers.addAll(baseHeaders);
          upstreamResp = await _client!.send(upstreamReq)
              .timeout(const Duration(seconds: 60));
          break;
        } catch (e) {
          lastError = e;
          if (attempt == 0) {
            await Future.delayed(const Duration(milliseconds: 500));
          }
        }
      }
      if (upstreamResp == null) throw lastError ?? Exception('Upstream fetch failed');

      // ── HLS manifest? Rewrite URLs so everything goes through the proxy ──
      final ct = upstreamResp.headers['content-type'] ?? '';
      if (!isHead && (_isHlsUrl(streamUrl) || _isHlsContentType(ct))) {
        await _serveRewrittenHls(req, upstreamResp, streamUrl);
        return;
      }

      // ── Set response headers from the initial upstream response ────────
      req.response.statusCode = upstreamResp.statusCode;

      for (final entry in upstreamResp.headers.entries) {
        switch (entry.key.toLowerCase()) {
          case 'content-type':
          case 'content-length':
          case 'content-range':
          case 'accept-ranges':
          case 'cache-control':
            req.response.headers.set(entry.key, entry.value);
        }
      }
      if (!upstreamResp.headers.containsKey('accept-ranges')) {
        req.response.headers.set('accept-ranges', 'bytes');
      }
      if (!upstreamResp.headers.containsKey('content-type')) {
        req.response.headers.set('content-type', _guessMime(streamUrl));
      }
      req.response.headers.set('Access-Control-Allow-Origin', '*');

      if (isHead) {
        await upstreamResp.stream.drain<void>();
        await req.response.close();
        return;
      }

      // ── Pipe data with auto-resume ─────────────────────────────────────
      // Determine expected total size so we know when to stop.
      final expectedLength = _parseExpectedLength(upstreamResp);
      int bytesSent = 0;

      // Pipe the initial response body
      await for (final chunk in upstreamResp.stream) {
        req.response.add(chunk);
        bytesSent += chunk.length;
      }

      // Auto-resume: if the CDN closed the connection before all bytes
      // were delivered (common with YouTube/CDN throttling), reconnect
      // with a Range header and keep piping.
      if (expectedLength != null && bytesSent < expectedLength) {
        // Calculate the absolute start offset (in case TV sent Range initially)
        int absoluteOffset = bytesSent;
        if (tvRange != null) {
          final match = RegExp(r'bytes=(\d+)-').firstMatch(tvRange);
          if (match != null) {
            absoluteOffset = int.parse(match.group(1)!) + bytesSent;
          }
        }

        const maxResumes = 500; // safety limit (~500 reconnections)
        for (var i = 0; i < maxResumes && bytesSent < expectedLength; i++) {
          try {
            final resumeHeaders = Map<String, String>.from(baseHeaders);
            resumeHeaders['Range'] = 'bytes=$absoluteOffset-';

            final resumeReq = http.Request('GET', Uri.parse(streamUrl))
              ..headers.addAll(resumeHeaders);
            final resumeResp = await _client!.send(resumeReq)
                .timeout(const Duration(seconds: 60));

            int chunkBytes = 0;
            await for (final chunk in resumeResp.stream) {
              req.response.add(chunk);
              chunkBytes += chunk.length;
            }

            if (chunkBytes == 0) break; // server returned empty — we're done
            bytesSent += chunkBytes;
            absoluteOffset += chunkBytes;
          } catch (_) {
            break; // can't resume further — deliver what we have
          }
        }
      }

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

  // ── HLS manifest rewriting ──────────────────────────────────────────────

  bool _isHlsUrl(String url) {
    final lower = url.toLowerCase().split('?').first;
    return lower.contains('.m3u8');
  }

  bool _isHlsContentType(String ct) {
    final lower = ct.toLowerCase();
    return lower.contains('mpegurl') || lower.contains('x-mpegurl');
  }

  /// Reads the full HLS manifest body, rewrites every URL to go through our
  /// /proxy endpoint, and serves the result to the TV.
  Future<void> _serveRewrittenHls(
      HttpRequest req, http.StreamedResponse resp, String manifestUrl) async {
    try {
      final bodyBytes = await resp.stream.toBytes();
      final manifest = utf8.decode(bodyBytes, allowMalformed: true);
      final rewritten = _rewriteHlsManifest(manifest, manifestUrl);

      req.response
        ..statusCode = 200
        ..headers.set('Content-Type', 'application/x-mpegURL; charset=utf-8')
        ..headers.set('Access-Control-Allow-Origin', '*')
        ..write(rewritten);
      await req.response.close();
    } catch (_) {
      try {
        req.response.statusCode = 502;
        await req.response.close();
      } catch (_) {}
    }
  }

  /// Rewrites all URLs in an HLS manifest (master or media playlist) so that
  /// each URL points to our local `/proxy?url=<encoded>` endpoint.
  String _rewriteHlsManifest(String manifest, String manifestUrl) {
    final baseUri = Uri.parse(manifestUrl);
    final lines = manifest.split('\n');
    final buf = StringBuffer();

    for (final line in lines) {
      if (line.startsWith('#')) {
        // Rewrite URI="..." in tags like #EXT-X-KEY, #EXT-X-MAP, etc.
        buf.writeln(_rewriteHlsTagUris(line, baseUri));
      } else if (line.trim().isNotEmpty) {
        // Non-comment, non-empty → segment or variant playlist URL
        final resolved = baseUri.resolve(line.trim()).toString();
        buf.writeln('$_baseUrl/proxy?url=${Uri.encodeComponent(resolved)}');
      } else {
        buf.writeln(line);
      }
    }

    return buf.toString();
  }

  /// Rewrites URI="..." attributes inside HLS tags (e.g. #EXT-X-KEY, #EXT-X-MAP).
  String _rewriteHlsTagUris(String line, Uri baseUri) {
    return line.replaceAllMapped(RegExp(r'URI="([^"]*)"'), (m) {
      final uri = m.group(1)!;
      final resolved = baseUri.resolve(uri).toString();
      return 'URI="$_baseUrl/proxy?url=${Uri.encodeComponent(resolved)}"';
    });
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _streamUrl = null;
    _baseUrl = null;
    _originHost = null;
    _extraHeaders = {};
    _subtitleSrt = null;
    _originalMimeType = null;
    _client?.close();
    _client = null;
  }

  /// Extracts the total expected body length from an upstream response.
  /// Returns `null` when unknown (e.g. chunked transfer without Content-Length).
  static int? _parseExpectedLength(http.StreamedResponse resp) {
    // For 206 Partial-Content, the full size is in "Content-Range: bytes 0-X/TOTAL"
    final cr = resp.headers['content-range'];
    if (cr != null) {
      final m = RegExp(r'/(\d+)').firstMatch(cr);
      if (m != null) {
        final start = RegExp(r'bytes (\d+)-').firstMatch(cr);
        final total = int.parse(m.group(1)!);
        final startOffset = start != null ? int.parse(start.group(1)!) : 0;
        return total - startOffset; // bytes expected in THIS response
      }
    }
    // Otherwise use Content-Length
    final cl = resp.headers['content-length'];
    if (cl != null) {
      return int.tryParse(cl);
    }
    return null;
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

  void dispose() {
    _client?.close();
    _client = null;
  }
}
