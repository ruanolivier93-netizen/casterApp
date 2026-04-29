import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

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

  /// Probed total file size (bytes) from HEAD request or HLS manifest.
  int? _probedContentLength;

  /// Probed total duration (seconds) from HLS manifest parsing.
  int? _probedDurationSeconds;

  bool get isRunning => _server != null;

  /// Total file size in bytes (probed at start). Null for HLS/unknown.
  int? get probedContentLength => _probedContentLength;

  /// Duration in seconds (probed from HLS manifest or upstream headers).
  int? get probedDurationSeconds => _probedDurationSeconds;

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

    // Probe the upstream stream to learn Content-Length and/or duration.
    // This info is used by DIDL metadata so the TV shows a proper
    // progress bar and enables seeking via the TV remote.
    await _probeStream(streamUrl);

    return _baseUrl;
  }

  /// The stream URL the TV should fetch.
  String? get streamEndpoint => _server == null
      ? null
      : 'http://${_server!.address.host}:${_server!.port}/stream';

  /// The subtitle URL the TV should fetch (null if no subs loaded).
  String? get subtitleEndpoint => _subtitleSrt != null && _server != null
      ? 'http://${_server!.address.host}:${_server!.port}/subtitle.srt'
      : null;

  /// WebVTT subtitle endpoint for Cast receivers.
  String? get subtitleVttEndpoint => _subtitleSrt != null && _server != null
      ? 'http://${_server!.address.host}:${_server!.port}/subtitle.vtt'
      : null;

  /// Probes the upstream stream to learn Content-Length and duration.
  /// Uses a **separate** HTTP client so we don't interfere with the main
  /// proxy client's connection pool.
  /// For HLS, fetches the manifest and sums `#EXTINF:` tags.
  /// For direct streams, does a HEAD request followed by a partial GET
  /// to discover Content-Length.
  Future<void> _probeStream(String streamUrl) async {
    _probedContentLength = null;
    _probedDurationSeconds = null;
    final probeClient = http.Client();
    try {
      final parsedUrl = Uri.parse(streamUrl);
      final ua = defaultTargetPlatform == TargetPlatform.iOS
          ? 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
              'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1'
          : 'Mozilla/5.0 (Linux; Android 14; Pixel 8) '
              'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';

      final headers = <String, String>{
        'User-Agent': ua,
        'Accept': '*/*',
        'Origin': _originHost ?? '${parsedUrl.scheme}://${parsedUrl.host}',
        'Referer': _originHost != null
            ? '$_originHost/'
            : '${parsedUrl.scheme}://${parsedUrl.host}/',
        ..._extraHeaders,
      };

      if (_isHlsUrl(streamUrl)) {
        // HLS — fetch manifest and calculate total duration from #EXTINF tags
        final req = http.Request('GET', Uri.parse(streamUrl))
          ..headers.addAll(headers);
        final resp =
            await probeClient.send(req).timeout(const Duration(seconds: 15));
        final body = await resp.stream.bytesToString();
        double totalDuration = 0;
        final extinfRegex = RegExp(r'#EXTINF:\s*([\d.]+)');
        for (final match in extinfRegex.allMatches(body)) {
          totalDuration += double.parse(match.group(1)!);
        }
        if (totalDuration > 0) {
          _probedDurationSeconds = totalDuration.round();
        }
        // If it's a master playlist (has stream variants), try fetching
        // the first variant to get segment durations.
        if (_probedDurationSeconds == null || _probedDurationSeconds == 0) {
          final variantRegex = RegExp(r'#EXT-X-STREAM-INF:.*\n(.+)');
          final variantMatch = variantRegex.firstMatch(body);
          if (variantMatch != null) {
            final variantUrl = Uri.parse(streamUrl)
                .resolve(variantMatch.group(1)!.trim())
                .toString();
            try {
              final vReq = http.Request('GET', Uri.parse(variantUrl))
                ..headers.addAll(headers);
              final vResp = await probeClient
                  .send(vReq)
                  .timeout(const Duration(seconds: 15));
              final vBody = await vResp.stream.bytesToString();
              double vDuration = 0;
              for (final m in extinfRegex.allMatches(vBody)) {
                vDuration += double.parse(m.group(1)!);
              }
              if (vDuration > 0) {
                _probedDurationSeconds = vDuration.round();
              }
            } catch (_) {}
          }
        }
      } else {
        // Direct stream — try HEAD first, then small Range GET as fallback
        // Many CDNs / movie sites don't respond to HEAD, so we try both.
        for (final method in ['HEAD', 'GET']) {
          try {
            final probHeaders = Map<String, String>.from(headers);
            if (method == 'GET') {
              // Only request first byte so CDN provides Content-Range with total size
              probHeaders['Range'] = 'bytes=0-0';
            }
            final req = http.Request(method, Uri.parse(streamUrl))
              ..headers.addAll(probHeaders);
            final resp = await probeClient
                .send(req)
                .timeout(const Duration(seconds: 15));
            await resp.stream.drain<void>();

            // Check Content-Range first (from 206 response)
            final cr = resp.headers['content-range'];
            if (cr != null) {
              final m = RegExp(r'/(\d+)').firstMatch(cr);
              if (m != null) {
                _probedContentLength = int.tryParse(m.group(1)!);
                break;
              }
            }
            // Fall back to Content-Length
            final cl = resp.headers['content-length'];
            if (cl != null) {
              final len = int.tryParse(cl);
              // For HEAD or a full 200, content-length is the file size.
              // For a Range: bytes=0-0 response (206), content-length is 1.
              if (len != null && len > 1) {
                _probedContentLength = len;
                break;
              }
            }
          } catch (_) {
            // Try next method
          }
        }
      }
    } catch (_) {
      // Probing is best-effort — don't block the cast if it fails.
    } finally {
      probeClient.close();
    }
  }

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

      if (path == '/subtitle.vtt' && _subtitleSrt != null) {
        req.response
          ..statusCode = 200
          ..headers.set('Content-Type', 'text/vtt; charset=utf-8')
          ..headers.set('Access-Control-Allow-Origin', '*')
          ..write(_toWebVtt(_subtitleSrt!));
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
        req.response.headers
            .set('Content-Range', 'bytes $start-$end/$fileLength');
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
  /// If the response is an HLS or DASH manifest, media URLs are rewritten to go
  /// through this proxy so the TV never contacts the CDN directly.
  ///
  /// Implements **auto-resume**: many CDNs (YouTube, lookmovie, etc.) throttle
  /// connections by sending an initial burst of data (~7-10 seconds) and then
  /// closing the connection, expecting the client to reconnect with a Range
  /// header for the next chunk.  We detect this and keep reconnecting until
  /// all data is delivered to the TV.
  Future<void> _proxyRemoteStream(HttpRequest req, String streamUrl) async {
    // Use a fresh client for each proxy request so stale connections don't
    // cause failures. The main _client is only used for probing.
    final reqClient = http.Client();
    try {
      final parsedUrl = Uri.parse(streamUrl);
      final isHead = req.method == 'HEAD';

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
        'Referer': _originHost != null
            ? '$_originHost/'
            : '${parsedUrl.scheme}://${parsedUrl.host}/',
        ..._extraHeaders,
      };

      // Forward Range header so the TV can seek within the stream.
      final tvRange = req.headers.value('range');
      if (tvRange != null) baseHeaders['Range'] = tvRange;

      // ── Initial upstream fetch (with retry) ────────────────────────────
      final method = isHead ? 'HEAD' : 'GET';
      http.StreamedResponse? upstreamResp;
      Object? lastError;
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          final upstreamReq = http.Request(method, Uri.parse(streamUrl))
            ..headers.addAll(baseHeaders);
          upstreamResp = await reqClient
              .send(upstreamReq)
              .timeout(const Duration(seconds: 60));
          break;
        } catch (e) {
          lastError = e;
          if (attempt < 2) {
            await Future.delayed(Duration(milliseconds: 500 * (attempt + 1)));
          }
        }
      }
      if (upstreamResp == null)
        throw lastError ?? Exception('Upstream fetch failed');

      // ── Adaptive manifest? Rewrite URLs so everything goes through the proxy ──
      final ct = upstreamResp.headers['content-type'] ?? '';
      if (!isHead && (_isHlsUrl(streamUrl) || _isHlsContentType(ct))) {
        await _serveRewrittenHls(req, upstreamResp, streamUrl);
        return;
      }
      if (!isHead && (_isDashUrl(streamUrl) || _isDashContentType(ct))) {
        await _serveRewrittenDash(req, upstreamResp, streamUrl);
        return;
      }

      // ── Determine the total file size ──────────────────────────────────
      // Use upstream response headers first, then fall back to probed value.
      int? totalFileSize = _parseExpectedLength(upstreamResp);
      if (totalFileSize == null && _probedContentLength != null) {
        totalFileSize = _probedContentLength;
      }

      final rangeMatch = tvRange != null
          ? RegExp(r'bytes=(\d+)-(\d*)').firstMatch(tvRange)
          : null;
      final requestedRangeStart =
          rangeMatch != null ? int.parse(rangeMatch.group(1)!) : null;
      final requestedRangeEnd =
          rangeMatch != null && (rangeMatch.group(2)?.isNotEmpty ?? false)
              ? int.parse(rangeMatch.group(2)!)
              : null;
      final rangeCapable = upstreamResp.statusCode == 206 ||
          upstreamResp.headers['accept-ranges']?.toLowerCase() == 'bytes';

      int? expectedResponseBytes;
      if (totalFileSize != null) {
        if (requestedRangeStart != null) {
          final requestedEnd = requestedRangeEnd ?? totalFileSize - 1;
          if (requestedRangeStart <= requestedEnd) {
            expectedResponseBytes = requestedEnd - requestedRangeStart + 1;
          }
        } else {
          expectedResponseBytes = totalFileSize;
        }
      }

      // ── Set response headers ───────────────────────────────────────────
      // Keep Range semantics aligned with what upstream actually returned.
      if (totalFileSize != null && tvRange == null) {
        req.response.statusCode = 200;
        req.response.headers.set('content-length', '$totalFileSize');
      } else if (requestedRangeStart != null &&
          upstreamResp.statusCode == 206) {
        req.response.statusCode = 206;
        final upstreamContentRange = upstreamResp.headers['content-range'];
        if (upstreamContentRange != null) {
          req.response.headers.set('content-range', upstreamContentRange);
        } else if (totalFileSize != null) {
          final requestedEnd = requestedRangeEnd ?? totalFileSize - 1;
          req.response.headers.set(
            'content-range',
            'bytes $requestedRangeStart-$requestedEnd/$totalFileSize',
          );
        }
        final upstreamContentLength = upstreamResp.headers['content-length'];
        if (upstreamContentLength != null) {
          req.response.headers.set('content-length', upstreamContentLength);
        } else if (expectedResponseBytes != null) {
          req.response.headers.set('content-length', '$expectedResponseBytes');
        }
      } else {
        req.response.statusCode = upstreamResp.statusCode;
        for (final entry in upstreamResp.headers.entries) {
          switch (entry.key.toLowerCase()) {
            case 'content-length':
            case 'content-range':
              req.response.headers.set(entry.key, entry.value);
          }
        }
      }

      final upstreamCt = upstreamResp.headers['content-type'];
      req.response.headers
          .set('content-type', upstreamCt ?? _guessMime(streamUrl));
      if (rangeCapable) {
        req.response.headers.set('accept-ranges', 'bytes');
      }
      req.response.headers.set('Access-Control-Allow-Origin', '*');

      if (isHead) {
        await upstreamResp.stream.drain<void>();
        await req.response.close();
        return;
      }

      // ── Pipe data with auto-resume ─────────────────────────────────────
      int bytesSent = 0;

      // Pipe the initial response body
      await for (final chunk in upstreamResp.stream) {
        req.response.add(chunk);
        bytesSent += chunk.length;
      }

      // ── Auto-resume when CDN closes connection prematurely ─────────────
      // Works two ways:
      //  1. Known size: resume when bytesSent < totalFileSize
      //  2. Unknown size: if we got some data but the stream closed
      //     suspiciously fast (< 30MB in under ~10 seconds of data),
      //     try one resume with Range header - if server accepts, keep going.
      final expectedLength = expectedResponseBytes;
      final needsResume =
          (expectedLength != null && bytesSent < expectedLength) ||
              (expectedLength == null &&
                  bytesSent > 0 &&
                  bytesSent < 30 * 1024 * 1024);

      if (needsResume) {
        int absoluteOffset = bytesSent;
        if (requestedRangeStart != null) {
          absoluteOffset = requestedRangeStart + bytesSent;
        }

        const maxResumes = 2000;
        for (var i = 0; i < maxResumes; i++) {
          // Stop if we've delivered everything
          if (expectedLength != null && bytesSent >= expectedLength) break;

          try {
            final resumeClient = http.Client();
            try {
              final resumeHeaders = Map<String, String>.from(baseHeaders);
              final resumeRange = requestedRangeEnd != null
                  ? 'bytes=$absoluteOffset-$requestedRangeEnd'
                  : 'bytes=$absoluteOffset-';
              // Remove any original Range the TV sent
              resumeHeaders.remove('range');
              resumeHeaders['Range'] = resumeRange;

              final resumeReq = http.Request('GET', Uri.parse(streamUrl))
                ..headers.addAll(resumeHeaders);
              final resumeResp = await resumeClient
                  .send(resumeReq)
                  .timeout(const Duration(seconds: 60));

              // If server returns 416 (Range Not Satisfiable), we're done
              if (resumeResp.statusCode == 416) {
                await resumeResp.stream.drain<void>();
                break;
              }
              // If server ignores Range on resume, stop before duplicating bytes.
              if (resumeResp.statusCode == 200) {
                await resumeResp.stream.drain<void>();
                break;
              }

              int chunkBytes = 0;
              await for (final chunk in resumeResp.stream) {
                req.response.add(chunk);
                chunkBytes += chunk.length;
              }

              if (chunkBytes == 0) break;
              bytesSent += chunkBytes;
              absoluteOffset += chunkBytes;
            } finally {
              resumeClient.close();
            }
          } catch (_) {
            break;
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

  bool _isDashUrl(String url) {
    final lower = url.toLowerCase().split('?').first;
    return lower.endsWith('.mpd');
  }

  bool _isDashContentType(String ct) {
    final lower = ct.toLowerCase();
    return lower.contains('application/dash+xml') ||
        lower.contains('application/xml+dash');
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

  Future<void> _serveRewrittenDash(
      HttpRequest req, http.StreamedResponse resp, String manifestUrl) async {
    try {
      final bodyBytes = await resp.stream.toBytes();
      final manifest = utf8.decode(bodyBytes, allowMalformed: true);
      final rewritten = _rewriteDashManifest(manifest, manifestUrl);

      req.response
        ..statusCode = 200
        ..headers.set('Content-Type', 'application/dash+xml; charset=utf-8')
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

  String _rewriteDashManifest(String manifest, String manifestUrl) {
    final document = XmlDocument.parse(manifest);
    final manifestUri = Uri.parse(manifestUrl);
    final root = document.rootElement;
    _rewriteDashElement(root, manifestUri);
    return document.toXmlString(pretty: false);
  }

  void _rewriteDashElement(XmlElement element, Uri inheritedBase) {
    final effectiveBase = _effectiveDashBase(element, inheritedBase);

    _rewriteDashAttributeIfPresent(element, 'media', effectiveBase,
        preserveTemplateTokens: true);
    _rewriteDashAttributeIfPresent(element, 'initialization', effectiveBase,
        preserveTemplateTokens: true);
    _rewriteDashAttributeIfPresent(element, 'sourceURL', effectiveBase);
    _rewriteDashAttributeIfPresent(element, 'index', effectiveBase,
        preserveTemplateTokens: true);
    _rewriteDashAttributeIfPresent(element, 'xlink:href', effectiveBase);
    _rewriteDashAttributeIfPresent(element, 'href', effectiveBase);
    _rewriteDashAttributeIfPresent(element, 'Location', effectiveBase);

    for (final baseUrl in element.children.whereType<XmlElement>()) {
      if (baseUrl.name.local != 'BaseURL') continue;
      final original = baseUrl.innerText.trim();
      if (original.isEmpty) continue;
      final resolved = inheritedBase.resolve(original).toString();
      baseUrl.children
        ..clear()
        ..add(XmlText(_buildProxyUrl(resolved)));
    }

    for (final child in element.children.whereType<XmlElement>()) {
      _rewriteDashElement(child, effectiveBase);
    }
  }

  Uri _effectiveDashBase(XmlElement element, Uri inheritedBase) {
    for (final child in element.children.whereType<XmlElement>()) {
      if (child.name.local != 'BaseURL') continue;
      final text = child.innerText.trim();
      if (text.isEmpty) continue;
      return inheritedBase.resolve(text);
    }
    return inheritedBase;
  }

  void _rewriteDashAttributeIfPresent(
    XmlElement element,
    String attributeName,
    Uri baseUri, {
    bool preserveTemplateTokens = false,
  }) {
    final attribute = element.getAttributeNode(attributeName) ??
        element.attributes
            .where((attr) => attr.name.qualified == attributeName)
            .firstOrNull;
    if (attribute == null) return;

    final value = attribute.value.trim();
    if (value.isEmpty) return;

    final resolved = baseUri.resolve(value).toString();
    attribute.value = _buildProxyUrl(
      resolved,
      preserveTemplateTokens: preserveTemplateTokens,
    );
  }

  /// Rewrites URI="..." attributes inside HLS tags (e.g. #EXT-X-KEY, #EXT-X-MAP).
  String _rewriteHlsTagUris(String line, Uri baseUri) {
    return line.replaceAllMapped(RegExp(r'URI="([^"]*)"'), (m) {
      final uri = m.group(1)!;
      final resolved = baseUri.resolve(uri).toString();
      return 'URI="${_buildProxyUrl(resolved)}"';
    });
  }

  String _buildProxyUrl(String resolvedUrl,
      {bool preserveTemplateTokens = true}) {
    return '$_baseUrl/proxy?url=${_encodeProxyUrl(resolvedUrl, preserveTemplateTokens: preserveTemplateTokens)}';
  }

  String _encodeProxyUrl(String url, {bool preserveTemplateTokens = true}) {
    final encoded = Uri.encodeComponent(url);
    if (!preserveTemplateTokens) return encoded;

    return encoded
        .replaceAll('%24', r'$')
        .replaceAll('%7B', '{')
        .replaceAll('%7D', '}');
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
    _probedContentLength = null;
    _probedDurationSeconds = null;
    _client?.close();
    _client = null;
  }

  String _toWebVtt(String srt) {
    final normalized = srt.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final lines = normalized.split('\n');
    final out = StringBuffer('WEBVTT\n\n');
    final timecode = RegExp(
      r'^(\d{2}:\d{2}:\d{2}),(\d{3})\s+-->\s+(\d{2}:\d{2}:\d{2}),(\d{3})(.*)$',
    );

    for (final line in lines) {
      final match = timecode.firstMatch(line.trim());
      if (match != null) {
        out.writeln(
          '${match.group(1)}.${match.group(2)} --> ${match.group(3)}.${match.group(4)}${match.group(5) ?? ''}',
        );
      } else {
        out.writeln(line);
      }
    }

    return out.toString();
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
    if (lower.endsWith('.mov') || lower.endsWith('.qt'))
      return 'video/quicktime';
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
