import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Runs a local HTTP server that proxies the video stream to the TV.
/// When "route through phone" is ON, the TV fetches from this server
/// and the phone fetches from the real source — handling auth headers,
/// geo-restrictions, and URLs the TV can't resolve itself.
class StreamProxyService {
  HttpServer? _server;
  String? _streamUrl;
  Map<String, String> _extraHeaders = {};

  // Persistent client for connection pooling — avoids TCP handshake overhead
  // per chunk and keeps connections alive for large streams.
  final _client = http.Client();

  bool get isRunning => _server != null;

  Future<String?> start({
    required String streamUrl,
    Map<String, String> extraHeaders = const {},
  }) async {
    await stop();

    _streamUrl = streamUrl;
    _extraHeaders = Map.of(extraHeaders);

    final ip = await _localIP();
    if (ip == null) return null;

    // Port 0 = OS assigns an available port automatically.
    // This eliminates the hardcoded-port-9876 collision bug.
    _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    final port = _server!.port;
    _serve();
    return 'http://$ip:$port/stream';
  }

  void _serve() {
    _server?.listen((req) async {
      final streamUrl = _streamUrl;
      if (streamUrl == null) {
        req.response.statusCode = 503;
        await req.response.close();
        return;
      }

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

        final upstreamResp = await _client.send(upstreamReq);

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
    });
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _streamUrl = null;
    _extraHeaders = {};
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
