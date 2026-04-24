import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:multicast_dns/multicast_dns.dart';

import '../models/dlna_device.dart';

/// Cast V2 protocol implementation for Chromecast devices.
///
/// Handles:
///   1. mDNS discovery of `_googlecast._tcp` services
///   2. TLS connection to port 8009
///   3. Protobuf-framed CastMessage encoding/decoding
///   4. Media loading, play/pause/seek/stop/volume
class ChromecastService {
  static const _defaultReceiverAppId = 'CC1AD845'; // Default Media Receiver

  // Cast V2 namespaces
  static const _nsConnection = 'urn:x-cast:com.google.cast.tp.connection';
  static const _nsHeartbeat = 'urn:x-cast:com.google.cast.tp.heartbeat';
  static const _nsReceiver = 'urn:x-cast:com.google.cast.receiver';
  static const _nsMedia = 'urn:x-cast:com.google.cast.media';

  SecureSocket? _socket;
  Timer? _heartbeatTimer;
  String? _transportId;
  int? _mediaSessionId;
  int _requestId = 0;
  final _responseCompleters = <int, Completer<Map<String, dynamic>>>{};
  StreamSubscription? _socketSub;
  final _buffer = BytesBuilder();

  // ── Discovery ───────────────────────────────────────────────────────────

  /// Discovers Chromecast devices via mDNS.
  Stream<DlnaDevice> discover(
      {Duration timeout = const Duration(seconds: 5)}) async* {
    final seen = <String>{};
    final client = MDnsClient();
    try {
      await client.start();

      // Discover PTR records for _googlecast._tcp.local
      await for (final ptr in client
          .lookup<PtrResourceRecord>(
            ResourceRecordQuery.serverPointer('_googlecast._tcp'),
          )
          .timeout(timeout, onTimeout: (sink) => sink.close())) {
        if (seen.contains(ptr.domainName)) continue;
        seen.add(ptr.domainName);

        String? host;
        int? port;
        String friendlyName = ptr.domainName.split('._googlecast').first;

        // Look up SRV for host:port
        await for (final srv in client.lookup<SrvResourceRecord>(
          ResourceRecordQuery.service(ptr.domainName),
        )) {
          port = srv.port;
          // Look up A record for IP
          await for (final a in client.lookup<IPAddressResourceRecord>(
            ResourceRecordQuery.addressIPv4(srv.target),
          )) {
            host = a.address.address;
            break;
          }
          break;
        }

        // Also try TXT for friendly name (fn=...)
        await for (final txt in client.lookup<TxtResourceRecord>(
          ResourceRecordQuery.text(ptr.domainName),
        )) {
          final fnEntry =
              txt.text.split('\n').where((l) => l.startsWith('fn='));
          if (fnEntry.isNotEmpty) {
            friendlyName = fnEntry.first.substring(3);
          }
          break;
        }

        if (host != null && port != null) {
          yield DlnaDevice(
            protocol: CastProtocol.chromecast,
            name: friendlyName,
            manufacturer: 'Google',
            location: 'chromecast://$host:$port',
            controlUrl: '', // Not used for Chromecast
            chromecastHost: host,
            chromecastPort: port,
          );
        }
      }
    } catch (_) {
      // mDNS might fail on some networks
    } finally {
      client.stop();
    }
  }

  // ── Connection ──────────────────────────────────────────────────────────

  Future<void> connect(DlnaDevice device) async {
    final host = device.chromecastHost;
    final port = device.chromecastPort ?? 8009;
    if (host == null) throw Exception('No Chromecast host');

    await disconnect();

    _socket = await SecureSocket.connect(
      host,
      port,
      onBadCertificate: (_) => true, // Chromecast uses self-signed certs
      timeout: const Duration(seconds: 5),
    );

    _buffer.clear();
    _socketSub = _socket!.listen(
      _onData,
      onError: (_) => disconnect(),
      onDone: disconnect,
    );

    // Open connection to receiver
    _sendMessage(
      _nsConnection,
      'receiver-0',
      jsonEncode({'type': 'CONNECT'}),
    );

    // Start heartbeat
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _sendMessage(_nsHeartbeat, 'receiver-0', jsonEncode({'type': 'PING'}));
    });
  }

  Future<void> disconnect() async {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _transportId = null;
    _mediaSessionId = null;
    _responseCompleters.clear();
    await _socketSub?.cancel();
    _socketSub = null;
    await _socket?.close();
    _socket = null;
  }

  bool get isConnected => _socket != null;

  // ── Media Control ───────────────────────────────────────────────────────

  Future<void> loadMedia({
    required String url,
    required String title,
    String contentType = 'video/mp4',
    String? subtitleUrl,
    int? durationSeconds,
  }) async {
    // Launch Default Media Receiver
    final launchResp = await _sendRequest(
      _nsReceiver,
      'receiver-0',
      {'type': 'LAUNCH', 'appId': _defaultReceiverAppId},
    );

    // Get transport ID from receiver status
    final apps = launchResp['status']?['applications'] as List?;
    if (apps == null || apps.isEmpty) {
      throw Exception('Failed to launch media receiver on Chromecast');
    }
    _transportId = apps[0]['transportId'] as String?;
    if (_transportId == null) throw Exception('No transport ID');

    // Connect to media session
    _sendMessage(
      _nsConnection,
      _transportId!,
      jsonEncode({'type': 'CONNECT'}),
    );
    await Future.delayed(const Duration(milliseconds: 300));

    // Build media info
    final media = <String, dynamic>{
      'contentId': url,
      'contentType': contentType,
      'streamType': 'BUFFERED',
      'metadata': {
        'type': 0,
        'metadataType': 0,
        'title': title,
      },
    };

    // Pass known duration so the receiver shows a seek bar and the TV
    // remote (CEC media keys, Google TV app) can scrub forward/back.
    if (durationSeconds != null && durationSeconds > 0) {
      media['duration'] = durationSeconds.toDouble();
    }

    // Add subtitle track if provided
    final tracks = <Map<String, dynamic>>[];
    if (subtitleUrl != null) {
      tracks.add({
        'trackId': 1,
        'type': 'TEXT',
        'trackContentId': subtitleUrl,
        'trackContentType': 'text/srt',
        'subtype': 'SUBTITLES',
        'name': 'Subtitles',
        'language': 'en',
      });
    }

    final loadPayload = <String, dynamic>{
      'type': 'LOAD',
      'media': media,
      'autoplay': true,
    };
    if (tracks.isNotEmpty) {
      loadPayload['media']['tracks'] = tracks;
      loadPayload['activeTrackIds'] = [1];
    }

    final resp = await _sendRequest(_nsMedia, _transportId!, loadPayload);
    _mediaSessionId = resp['mediaSessionId'] as int? ??
        (resp['status'] is List && (resp['status'] as List).isNotEmpty
            ? (resp['status'] as List)[0]['mediaSessionId'] as int?
            : null);
  }

  Future<void> play() async {
    if (_transportId == null || _mediaSessionId == null) return;
    await _sendRequest(_nsMedia, _transportId!, {
      'type': 'PLAY',
      'mediaSessionId': _mediaSessionId,
    });
  }

  Future<void> pause() async {
    if (_transportId == null || _mediaSessionId == null) return;
    await _sendRequest(_nsMedia, _transportId!, {
      'type': 'PAUSE',
      'mediaSessionId': _mediaSessionId,
    });
  }

  Future<void> stop() async {
    if (_transportId == null || _mediaSessionId == null) return;
    try {
      await _sendRequest(_nsMedia, _transportId!, {
        'type': 'STOP',
        'mediaSessionId': _mediaSessionId,
      });
    } catch (_) {}
    _mediaSessionId = null;
  }

  Future<void> seek(Duration position) async {
    if (_transportId == null) return;
    await _ensureMediaSession();
    if (_mediaSessionId == null) return;

    final payload = {
      'type': 'SEEK',
      'mediaSessionId': _mediaSessionId,
      'currentTime': position.inMilliseconds / 1000.0,
      // Ensures receiver keeps playback active after seek when possible.
      'resumeState': 'PLAYBACK_START',
    };

    try {
      await _sendRequest(_nsMedia, _transportId!, payload);
    } catch (_) {
      // Some receivers rotate mediaSessionId after buffering/seek boundaries.
      // Refresh and retry once before bubbling the error up.
      await _ensureMediaSession(forceRefresh: true);
      if (_mediaSessionId == null) rethrow;
      await _sendRequest(_nsMedia, _transportId!, {
        ...payload,
        'mediaSessionId': _mediaSessionId,
      });
    }
  }

  Future<void> _ensureMediaSession({bool forceRefresh = false}) async {
    if (!forceRefresh && _mediaSessionId != null) return;
    if (_transportId == null) return;
    try {
      final resp = await _sendRequest(_nsMedia, _transportId!, {
        'type': 'GET_STATUS',
      });
      final statuses = resp['status'] as List?;
      if (statuses != null && statuses.isNotEmpty) {
        _mediaSessionId = statuses[0]['mediaSessionId'] as int?;
      }
    } catch (_) {
      // Keep existing session state if status refresh fails.
    }
  }

  Future<void> setVolume(double level) async {
    await _sendRequest(_nsReceiver, 'receiver-0', {
      'type': 'SET_VOLUME',
      'volume': {'level': level.clamp(0.0, 1.0)},
    });
  }

  /// Returns (position, duration, playerState) or null if unavailable.
  Future<({Duration position, Duration duration, String state})?>
      getMediaStatus() async {
    if (_transportId == null) return null;
    // Auto-recover stale media sessions (receiver rotates the id after seek
    // boundaries, ad insertions, segment gaps, etc.).
    if (_mediaSessionId == null) {
      await _ensureMediaSession(forceRefresh: true);
      if (_mediaSessionId == null) return null;
    }
    try {
      final resp = await _sendRequest(_nsMedia, _transportId!, {
        'type': 'GET_STATUS',
        'mediaSessionId': _mediaSessionId,
      });
      final statuses = resp['status'] as List?;
      if (statuses == null || statuses.isEmpty) {
        // Empty status often means the session id is stale — refresh once.
        await _ensureMediaSession(forceRefresh: true);
        return null;
      }
      final s = statuses[0] as Map<String, dynamic>;
      // Keep our session id in sync if the receiver swapped it.
      final reportedId = s['mediaSessionId'] as int?;
      if (reportedId != null) _mediaSessionId = reportedId;
      final pos = (s['currentTime'] as num?)?.toDouble() ?? 0;
      final dur = (s['media']?['duration'] as num?)?.toDouble() ?? 0;
      final state = s['playerState'] as String? ?? 'UNKNOWN';
      return (
        position: Duration(milliseconds: (pos * 1000).round()),
        duration: Duration(milliseconds: (dur * 1000).round()),
        state: state,
      );
    } catch (_) {
      // On failure, mark session for refresh on next call.
      _mediaSessionId = null;
      return null;
    }
  }

  // ── Cast V2 Protocol Layer ──────────────────────────────────────────────

  int get _nextRequestId => ++_requestId;

  Future<Map<String, dynamic>> _sendRequest(
    String namespace,
    String destination,
    Map<String, dynamic> payload,
  ) {
    final id = _nextRequestId;
    payload['requestId'] = id;
    final completer = Completer<Map<String, dynamic>>();
    _responseCompleters[id] = completer;

    _sendMessage(namespace, destination, jsonEncode(payload));

    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _responseCompleters.remove(id);
        throw TimeoutException('Chromecast request timed out');
      },
    );
  }

  void _sendMessage(String namespace, String destination, String payload) {
    final socket = _socket;
    if (socket == null) return;

    final msg = _encodeCastMessage(
      sourceId: 'sender-0',
      destinationId: destination,
      namespace: namespace,
      payload: payload,
    );

    // Frame: 4-byte big-endian length + protobuf message
    final frame = Uint8List(4 + msg.length);
    final view = ByteData.view(frame.buffer);
    view.setUint32(0, msg.length, Endian.big);
    frame.setRange(4, frame.length, msg);
    socket.add(frame);
  }

  void _onData(Uint8List data) {
    _buffer.add(data);
    _processBuffer();
  }

  void _processBuffer() {
    while (true) {
      final bytes = _buffer.toBytes();
      if (bytes.length < 4) return;

      final view = ByteData.view(bytes.buffer, bytes.offsetInBytes);
      final msgLen = view.getUint32(0, Endian.big);
      if (bytes.length < 4 + msgLen) return;

      final msgBytes = bytes.sublist(4, 4 + msgLen);
      final remaining = bytes.sublist(4 + msgLen);
      _buffer.clear();
      if (remaining.isNotEmpty) _buffer.add(remaining);

      _handleMessage(msgBytes);
    }
  }

  void _handleMessage(Uint8List data) {
    try {
      final msg = _decodeCastMessage(data);
      if (msg == null) return;

      // Handle heartbeat PONGs silently
      if (msg.namespace == _nsHeartbeat) return;

      final payload = jsonDecode(msg.payload) as Map<String, dynamic>;
      final requestId = payload['requestId'] as int?;

      if (requestId != null && _responseCompleters.containsKey(requestId)) {
        _responseCompleters.remove(requestId)?.complete(payload);
      }

      // Update media session ID from status updates
      if (msg.namespace == _nsMedia) {
        final statuses = payload['status'] as List?;
        if (statuses != null && statuses.isNotEmpty) {
          _mediaSessionId = statuses[0]['mediaSessionId'] as int?;
        }
      }
    } catch (_) {}
  }

  // ── Manual Protobuf Encoding (CastMessage) ─────────────────────────────
  //
  // CastMessage proto:
  //   field 1: protocol_version (varint) = 0 (CASTV2_1_0)
  //   field 2: source_id (length-delimited string)
  //   field 3: destination_id (length-delimited string)
  //   field 4: namespace (length-delimited string)
  //   field 5: payload_type (varint) = 0 (STRING)
  //   field 6: payload_utf8 (length-delimited string)

  static Uint8List _encodeCastMessage({
    required String sourceId,
    required String destinationId,
    required String namespace,
    required String payload,
  }) {
    final builder = BytesBuilder();
    // Field 1: protocol_version = 0
    builder.addByte(0x08); // tag: field 1, wire type 0 (varint)
    builder.addByte(0x00); // value: 0

    // Field 2: source_id
    _writeString(builder, 0x12, sourceId);
    // Field 3: destination_id
    _writeString(builder, 0x1A, destinationId);
    // Field 4: namespace
    _writeString(builder, 0x22, namespace);

    // Field 5: payload_type = 0 (STRING)
    builder.addByte(0x28);
    builder.addByte(0x00);

    // Field 6: payload_utf8
    _writeString(builder, 0x32, payload);

    return builder.toBytes();
  }

  static void _writeString(BytesBuilder builder, int tag, String value) {
    final bytes = utf8.encode(value);
    builder.addByte(tag);
    _writeVarint(builder, bytes.length);
    builder.add(bytes);
  }

  static void _writeVarint(BytesBuilder builder, int value) {
    var v = value;
    while (v > 0x7F) {
      builder.addByte((v & 0x7F) | 0x80);
      v >>= 7;
    }
    builder.addByte(v & 0x7F);
  }

  static _CastMsg? _decodeCastMessage(Uint8List data) {
    String? sourceId, destinationId, namespace, payload;
    int offset = 0;

    while (offset < data.length) {
      if (offset >= data.length) break;
      final tag = data[offset++];
      final fieldNumber = tag >> 3;
      final wireType = tag & 0x07;

      if (wireType == 0) {
        // Varint — read and discard
        while (offset < data.length && (data[offset] & 0x80) != 0) {
          offset++;
        }
        if (offset < data.length) offset++;
      } else if (wireType == 2) {
        // Length-delimited
        final (len, newOffset) = _readVarint(data, offset);
        offset = newOffset;
        if (offset + len > data.length) break;
        final bytes = data.sublist(offset, offset + len);
        offset += len;

        switch (fieldNumber) {
          case 2:
            sourceId = utf8.decode(bytes, allowMalformed: true);
          case 3:
            destinationId = utf8.decode(bytes, allowMalformed: true);
          case 4:
            namespace = utf8.decode(bytes, allowMalformed: true);
          case 6:
            payload = utf8.decode(bytes, allowMalformed: true);
        }
      } else {
        break; // Unknown wire type
      }
    }

    if (namespace == null || payload == null) return null;
    return _CastMsg(
      sourceId: sourceId ?? '',
      destinationId: destinationId ?? '',
      namespace: namespace,
      payload: payload,
    );
  }

  static (int, int) _readVarint(Uint8List data, int offset) {
    int result = 0;
    int shift = 0;
    while (offset < data.length) {
      final byte = data[offset++];
      result |= (byte & 0x7F) << shift;
      if ((byte & 0x80) == 0) break;
      shift += 7;
    }
    return (result, offset);
  }
}

class _CastMsg {
  final String sourceId;
  final String destinationId;
  final String namespace;
  final String payload;
  const _CastMsg({
    required this.sourceId,
    required this.destinationId,
    required this.namespace,
    required this.payload,
  });
}
