import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:http/http.dart' as http;
import '../models/video_info.dart';

class VideoExtractorService {
  final _yt = YoutubeExplode();

  Future<VideoInfo> extract(String url) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme || !uri.scheme.startsWith('http')) {
      throw Exception(
        'Please enter a valid URL starting with http:// or https://',
      );
    }

    final host = uri.host.toLowerCase();
    if (host.contains('youtube.com') || host.contains('youtu.be')) {
      return _extractYouTube(url);
    }
    return _extractDirect(url);
  }

  Future<VideoInfo> _extractYouTube(String url) async {
    final video = await _yt.videos.get(url);
    final manifest = await _yt.videos.streamsClient.getManifest(video.id);

    final formats = <StreamFormat>[];

    // Muxed (video + audio in one stream) — always prefer these.
    // sortByVideoQuality() returns ascending; reverse to put highest first.
    final muxed = manifest.muxed.sortByVideoQuality().toList().reversed.toList();
    for (int i = 0; i < muxed.length; i++) {
      final s = muxed[i];
      formats.add(StreamFormat(
        id: 'muxed_$i',
        label: '${s.videoResolution.height}p · mp4 · video+audio',
        url: s.url.toString(),
        height: s.videoResolution.height,
        hasAudio: true,
        filesize: s.size.totalBytes,
      ));
    }

    // If no muxed streams exist (rare), fall back to video-only adaptive.
    if (formats.isEmpty) {
      final adaptive = manifest.videoOnly.sortByVideoQuality().toList().reversed.toList();
      for (int i = 0; i < adaptive.length; i++) {
        final s = adaptive[i];
        formats.add(StreamFormat(
          id: 'video_$i',
          label: '${s.videoResolution.height}p · ${s.container.name} · video only ⚠',
          url: s.url.toString(),
          height: s.videoResolution.height,
          hasAudio: false,
          filesize: s.size.totalBytes,
        ));
      }
    }

    return VideoInfo(
      title: video.title,
      thumbnailUrl: video.thumbnails.highResUrl,
      durationSeconds: video.duration?.inSeconds,
      uploader: video.author,
      formats: formats,
    );
  }

  Future<VideoInfo> _extractDirect(String url) async {
    final isLikelyVideo = url.contains('.mp4') ||
        url.contains('.m3u8') ||
        url.contains('.webm') ||
        url.contains('.mkv') ||
        url.contains('.avi') ||
        url.contains('.mov');

    if (!isLikelyVideo) {
      try {
        final response = await http.head(Uri.parse(url)).timeout(const Duration(seconds: 8));
        final ct = response.headers['content-type'] ?? '';
        if (!ct.contains('video/') &&
            !ct.contains('application/x-mpegurl') &&
            !ct.contains('application/vnd.apple.mpegurl') &&
            !ct.contains('application/octet-stream')) {
          throw Exception(
            'This URL doesn\'t appear to be a direct video link.\n'
            'Supported: YouTube, or direct .mp4 / .m3u8 / .webm URLs.',
          );
        }
      } catch (e) {
        if (e.toString().contains('Supported:')) rethrow;
        // Swallow HEAD errors (server may not allow HEAD) and try anyway
      }
    }

    final uri = Uri.parse(url);
    // Decode percent-encoded characters (e.g. %20 → space) for display.
    final raw = uri.pathSegments.isNotEmpty
        ? Uri.decodeComponent(uri.pathSegments.last.split('?').first)
        : '';
    final filename = raw.isNotEmpty ? raw : 'Direct Stream';

    return VideoInfo(
      title: filename.isNotEmpty ? filename : 'Direct Stream',
      formats: [
        StreamFormat(
          id: 'direct',
          label: 'Direct stream',
          url: url,
          height: 0,
          hasAudio: true,
        ),
      ],
    );
  }

  void dispose() => _yt.close();
}
