class StreamFormat {
  final String id;
  final String label;
  final String url;
  final int height;
  final bool hasAudio;
  final int? filesize;

  const StreamFormat({
    required this.id,
    required this.label,
    required this.url,
    required this.height,
    required this.hasAudio,
    this.filesize,
  });
}

class VideoInfo {
  final String title;
  final String? thumbnailUrl;
  final int? durationSeconds;
  final String? uploader;
  final List<StreamFormat> formats;

  const VideoInfo({
    required this.title,
    this.thumbnailUrl,
    this.durationSeconds,
    this.uploader,
    required this.formats,
  });
}
