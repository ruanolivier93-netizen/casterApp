import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';
import '../models/dlna_device.dart';
import 'multicast_lock.dart';

class PositionInfo {
  final Duration position;
  final Duration duration;
  final String transportState; // PLAYING, PAUSED_PLAYBACK, STOPPED, NO_MEDIA_PRESENT
  const PositionInfo({
    required this.position,
    required this.duration,
    required this.transportState,
  });
}

class DlnaService {
  static const _ssdpAddress = '239.255.255.250';
  static const _ssdpPort = 1900;
  static const _avTransportUrn = 'urn:schemas-upnp-org:service:AVTransport:1';
  static const _renderingControlUrn = 'urn:schemas-upnp-org:service:RenderingControl:1';
  static const _searchTargets = [
    'urn:schemas-upnp-org:device:MediaRenderer:1',
    'urn:schemas-upnp-org:service:AVTransport:1',
    'ssdp:all',
  ];

  // ── Device Discovery ────────────────────────────────────────────────────────

  /// Discovers DLNA renderers. Returns results as they're found up to [timeout].
  Future<List<DlnaDevice>> discover({Duration timeout = const Duration(seconds: 6)}) async {
    await MulticastLock.acquire();
    try {
      final devices = <DlnaDevice>[];
      final seen = <String>{};
      await Future.wait(
        _searchTargets.map((target) => _ssdpSearch(
              searchTarget: target,
              timeout: timeout,
              seen: seen,
              devices: devices,
            )),
      );
      return devices;
    } finally {
      await MulticastLock.release();
    }
  }

  /// Stream-based discovery that yields devices as they arrive.
  /// This is used for *live updating* UI — devices appear immediately.
  Stream<DlnaDevice> discoverStream({Duration timeout = const Duration(seconds: 8)}) async* {
    await MulticastLock.acquire();
    final controller = StreamController<DlnaDevice>();
    final seen = <String>{};

    Future<void> search(String target) async {
      RawDatagramSocket? socket;
      try {
        socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
        socket.multicastHops = 4;
        socket.broadcastEnabled = true;
        // Join the SSDP multicast group so replies can be received.
        try {
          socket.joinMulticast(InternetAddress(_ssdpAddress));
        } catch (_) {}

        final message = utf8.encode(
          'M-SEARCH * HTTP/1.1\r\n'
          'HOST: $_ssdpAddress:$_ssdpPort\r\n'
          'MAN: "ssdp:discover"\r\n'
          'MX: 2\r\n'
          'ST: $target\r\n'
          '\r\n',
        );

        // Send the search packet 3 times for reliability (UDP can drop packets).
        socket.send(message, InternetAddress(_ssdpAddress), _ssdpPort);
        await Future.delayed(const Duration(milliseconds: 100));
        socket.send(message, InternetAddress(_ssdpAddress), _ssdpPort);
        await Future.delayed(const Duration(milliseconds: 200));
        socket.send(message, InternetAddress(_ssdpAddress), _ssdpPort);

        final completer = Completer<void>();
        final timer = Timer(timeout, () {
          if (!completer.isCompleted) completer.complete();
        });

        socket.listen((event) async {
          if (event == RawSocketEvent.read) {
            final datagram = socket!.receive();
            if (datagram == null) return;
            final text = utf8.decode(datagram.data, allowMalformed: true);
            final m = RegExp(r'LOCATION:\s*(\S+)', caseSensitive: false).firstMatch(text);
            if (m == null) return;
            final location = m.group(1)!.trim();
            if (seen.contains(location)) return;
            seen.add(location);
            try {
              final device = await _fetchDeviceInfo(location);
              if (device != null && !controller.isClosed) {
                controller.add(device);
              }
            } catch (_) {}
          }
        });

        await completer.future;
        timer.cancel();
      } catch (_) {
      } finally {
        socket?.close();
      }
    }

    // Run both searches in parallel
    final searchFuture = Future.wait(
      _searchTargets.map((t) => search(t)),
    );

    // Yield devices as they arrive
    yield* controller.stream.timeout(
      timeout + const Duration(seconds: 1),
      onTimeout: (sink) => sink.close(),
    );

    await searchFuture;
    await controller.close();
    await MulticastLock.release();
  }

  Future<void> _ssdpSearch({
    required String searchTarget,
    required Duration timeout,
    required Set<String> seen,
    required List<DlnaDevice> devices,
  }) async {
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.multicastHops = 4;
      socket.broadcastEnabled = true;
      try {
        socket.joinMulticast(InternetAddress(_ssdpAddress));
      } catch (_) {}

      final message = utf8.encode(
        'M-SEARCH * HTTP/1.1\r\n'
        'HOST: $_ssdpAddress:$_ssdpPort\r\n'
        'MAN: "ssdp:discover"\r\n'
        'MX: 3\r\n'
        'ST: $searchTarget\r\n'
        '\r\n',
      );

      // Send multiple times — UDP is unreliable.
      socket.send(message, InternetAddress(_ssdpAddress), _ssdpPort);
      await Future.delayed(const Duration(milliseconds: 100));
      socket.send(message, InternetAddress(_ssdpAddress), _ssdpPort);
      await Future.delayed(const Duration(milliseconds: 200));
      socket.send(message, InternetAddress(_ssdpAddress), _ssdpPort);

      final completer = Completer<void>();
      final timer = Timer(timeout, () {
        if (!completer.isCompleted) completer.complete();
      });

      socket.listen((event) async {
        if (event == RawSocketEvent.read) {
          final datagram = socket!.receive();
          if (datagram == null) return;
          final text = utf8.decode(datagram.data, allowMalformed: true);
          final m = RegExp(r'LOCATION:\s*(\S+)', caseSensitive: false).firstMatch(text);
          if (m == null) return;
          final location = m.group(1)!.trim();
          if (seen.contains(location)) return;
          seen.add(location);
          try {
            final device = await _fetchDeviceInfo(location);
            if (device != null) devices.add(device);
          } catch (_) {}
        }
      });

      await completer.future;
      timer.cancel();
    } catch (_) {
    } finally {
      socket?.close();
    }
  }

  Future<DlnaDevice?> _fetchDeviceInfo(String location) async {
    final response = await http
        .get(Uri.parse(location))
        .timeout(const Duration(seconds: 5));
    if (response.statusCode != 200) return null;

    final doc = XmlDocument.parse(response.body);
    final deviceEl = doc.findAllElements('device').firstOrNull;
    if (deviceEl == null) return null;

    final name =
        deviceEl.findElements('friendlyName').firstOrNull?.innerText ?? 'Unknown Device';
    final manufacturer =
        deviceEl.findElements('manufacturer').firstOrNull?.innerText ?? '';

    // Walk all services (including embedded devices) to find AVTransport and
    // RenderingControl URLs.
    String? controlUrl;
    String? renderingControlUrl;
    for (final svc in doc.findAllElements('service')) {
      final type = svc.findElements('serviceType').firstOrNull?.innerText ?? '';
      if (type.contains('AVTransport') && controlUrl == null) {
        controlUrl = svc.findElements('controlURL').firstOrNull?.innerText;
      }
      if (type.contains('RenderingControl') && renderingControlUrl == null) {
        renderingControlUrl = svc.findElements('controlURL').firstOrNull?.innerText;
      }
    }
    if (controlUrl == null) return null;

    // Make URLs absolute.
    final base = Uri.parse(location);
    String makeAbsolute(String url) {
      if (url.startsWith('http')) return url;
      final rel = url.startsWith('/') ? url : '/$url';
      return '${base.scheme}://${base.host}:${base.port}$rel';
    }

    return DlnaDevice(
      name: name,
      manufacturer: manufacturer,
      location: location,
      controlUrl: makeAbsolute(controlUrl),
      renderingControlUrl:
          renderingControlUrl != null ? makeAbsolute(renderingControlUrl) : null,
    );
  }

  // ── AVTransport Control ─────────────────────────────────────────────────────

  Future<void> setUri(DlnaDevice device, String uri, String title, {
    String? subtitleUrl,
    int? durationSeconds,
    String? contentType,
  }) async {
    final metadata = _buildDIDL(title, uri,
        subtitleUrl: subtitleUrl, durationSeconds: durationSeconds,
        contentType: contentType);
    await _soap(
      device.controlUrl,
      'SetAVTransportURI',
      '<InstanceID>0</InstanceID>'
      '<CurrentURI>${_esc(uri)}</CurrentURI>'
      '<CurrentURIMetaData>${_esc(metadata)}</CurrentURIMetaData>',
    );
  }

  Future<void> play(DlnaDevice device) =>
      _soap(device.controlUrl, 'Play', '<InstanceID>0</InstanceID><Speed>1</Speed>');

  Future<void> pause(DlnaDevice device) =>
      _soap(device.controlUrl, 'Pause', '<InstanceID>0</InstanceID>');

  Future<void> stop(DlnaDevice device) =>
      _soap(device.controlUrl, 'Stop', '<InstanceID>0</InstanceID>');

  Future<void> seek(DlnaDevice device, Duration position) {
    final h = position.inHours.toString().padLeft(2, '0');
    final m = (position.inMinutes % 60).toString().padLeft(2, '0');
    final s = (position.inSeconds % 60).toString().padLeft(2, '0');
    return _soap(
      device.controlUrl,
      'Seek',
      '<InstanceID>0</InstanceID><Unit>REL_TIME</Unit><Target>$h:$m:$s</Target>',
    );
  }

  Future<void> setVolume(DlnaDevice device, int volume) async {
    final url = device.renderingControlUrl;
    if (url == null) return; // Device doesn't expose RenderingControl.
    await _soapAction(
      url: url,
      urn: _renderingControlUrn,
      action: 'SetVolume',
      args: '<InstanceID>0</InstanceID>'
          '<Channel>Master</Channel>'
          '<DesiredVolume>${volume.clamp(0, 100)}</DesiredVolume>',
    );
  }

  Future<int?> getVolume(DlnaDevice device) async {
    final url = device.renderingControlUrl;
    if (url == null) return null;
    try {
      final response = await _soapAction(
        url: url,
        urn: _renderingControlUrn,
        action: 'GetVolume',
        args: '<InstanceID>0</InstanceID><Channel>Master</Channel>',
      );
      final doc = XmlDocument.parse(response);
      final val = doc.findAllElements('CurrentVolume').firstOrNull?.innerText;
      return int.tryParse(val ?? '');
    } catch (_) {
      return null;
    }
  }

  Future<PositionInfo> getPositionInfo(DlnaDevice device) async {
    final response =
        await _soap(device.controlUrl, 'GetPositionInfo', '<InstanceID>0</InstanceID>');
    final doc = XmlDocument.parse(response);
    final relTime = doc.findAllElements('RelTime').firstOrNull?.innerText;
    final trackDuration = doc.findAllElements('TrackDuration').firstOrNull?.innerText;

    final transResponse =
        await _soap(device.controlUrl, 'GetTransportInfo', '<InstanceID>0</InstanceID>');
    final transDoc = XmlDocument.parse(transResponse);
    final state =
        transDoc.findAllElements('CurrentTransportState').firstOrNull?.innerText ?? 'UNKNOWN';

    return PositionInfo(
      position: _parseDuration(relTime),
      duration: _parseDuration(trackDuration),
      transportState: state,
    );
  }

  // ── Internals ───────────────────────────────────────────────────────────────

  // Convenience wrapper for AVTransport actions.
  Future<String> _soap(String url, String action, String args) =>
      _soapAction(url: url, urn: _avTransportUrn, action: action, args: args);

  Future<String> _soapAction({
    required String url,
    required String urn,
    required String action,
    required String args,
  }) async {
    final body =
        '<?xml version="1.0" encoding="utf-8"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        '<s:Body>'
        '<u:$action xmlns:u="$urn">$args</u:$action>'
        '</s:Body>'
        '</s:Envelope>';

    final response = await http
        .post(
          Uri.parse(url),
          headers: {
            'Content-Type': 'text/xml; charset="utf-8"',
            'SOAPAction': '"$urn#$action"',
          },
          body: utf8.encode(body),
        )
        .timeout(const Duration(seconds: 8));

    if (response.statusCode >= 300) {
      throw Exception('DLNA $action failed (${response.statusCode})');
    }
    return utf8.decode(response.bodyBytes);
  }

  String _buildDIDL(String title, String uri, {
    String? subtitleUrl,
    int? durationSeconds,
    String? contentType,
  }) {
    final mime = contentType ?? _mimeType(uri);
    final isAudio = mime.startsWith('audio/');
    final upnpClass = isAudio ? 'object.item.audioItem.musicTrack' : 'object.item.videoItem';

    // Build the <res> attribute string with optional duration.
    final resBuf = StringBuffer('protocolInfo="http-get:*:$mime:*"');
    if (durationSeconds != null && durationSeconds > 0) {
      final h = (durationSeconds ~/ 3600).toString().padLeft(2, '0');
      final m = ((durationSeconds % 3600) ~/ 60).toString().padLeft(2, '0');
      final s = (durationSeconds % 60).toString().padLeft(2, '0');
      resBuf.write(' duration="$h:$m:$s"');
    }

    // Samsung-style <sec:CaptionInfoEx> for subtitles — most widely supported.
    var captionTag = '';
    if (subtitleUrl != null) {
      captionTag =
          '<sec:CaptionInfoEx sec:type="srt" xmlns:sec="http://www.sec.co.kr/">'
          '${_esc(subtitleUrl)}'
          '</sec:CaptionInfoEx>'
          '<res protocolInfo="http-get:*:application/x-subrip:*">'
          '${_esc(subtitleUrl)}'
          '</res>';
    }

    return '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/" '
        'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" '
        'xmlns:sec="http://www.sec.co.kr/">'
        '<item id="0" parentID="-1" restricted="1">'
        '<dc:title>${_esc(title)}</dc:title>'
        '<upnp:class>$upnpClass</upnp:class>'
        '<res $resBuf>${_esc(uri)}</res>'
        '$captionTag'
        '</item>'
        '</DIDL-Lite>';
  }

  String _mimeType(String uri) {
    final lower = uri.toLowerCase().split('?').first;
    // HLS / DASH
    if (lower.contains('.m3u8')) return 'video/x-mpegurl';
    if (lower.endsWith('.mpd')) return 'application/dash+xml';
    // Video
    if (lower.endsWith('.webm')) return 'video/webm';
    if (lower.endsWith('.mkv')) return 'video/x-matroska';
    if (lower.endsWith('.avi')) return 'video/x-msvideo';
    if (lower.endsWith('.mov') || lower.endsWith('.qt')) return 'video/quicktime';
    if (lower.endsWith('.ts')) return 'video/mp2t';
    if (lower.endsWith('.flv')) return 'video/x-flv';
    if (lower.endsWith('.3gp')) return 'video/3gpp';
    if (lower.endsWith('.wmv')) return 'video/x-ms-wmv';
    if (lower.endsWith('.m4v')) return 'video/mp4';
    // Audio
    if (lower.endsWith('.mp3')) return 'audio/mpeg';
    if (lower.endsWith('.aac') || lower.endsWith('.m4a')) return 'audio/mp4';
    if (lower.endsWith('.flac')) return 'audio/flac';
    if (lower.endsWith('.ogg') || lower.endsWith('.oga')) return 'audio/ogg';
    if (lower.endsWith('.wav')) return 'audio/wav';
    if (lower.endsWith('.wma')) return 'audio/x-ms-wma';
    if (lower.endsWith('.opus')) return 'audio/opus';
    return 'video/mp4'; // Safe default for most direct streams.
  }

  String _esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  Duration _parseDuration(String? t) {
    if (t == null || t == 'NOT_IMPLEMENTED' || t == '0:00:00') return Duration.zero;
    final parts = t.split(':');
    if (parts.length < 3) return Duration.zero;
    return Duration(
      hours: int.tryParse(parts[0]) ?? 0,
      minutes: int.tryParse(parts[1]) ?? 0,
      seconds: int.tryParse(parts[2].split('.').first) ?? 0,
    );
  }
}
