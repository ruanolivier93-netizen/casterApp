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

class SubtitleTrack {
  final String language;   // e.g. "en", "fr"
  final String label;      // e.g. "English", "English (auto)"
  final String srtContent; // full SRT subtitle text
  const SubtitleTrack({
    required this.language,
    required this.label,
    required this.srtContent,
  });
}

class VideoInfo {
  final String title;
  final String? thumbnailUrl;
  final int? durationSeconds;
  final String? uploader;
  final List<StreamFormat> formats;
  final List<SubtitleTrack> subtitles;

  const VideoInfo({
    required this.title,
    this.thumbnailUrl,
    this.durationSeconds,
    this.uploader,
    required this.formats,
    this.subtitles = const [],
  });
}
