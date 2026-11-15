/// One generated audio saved on the device.
class AudioItem {
  final String id;
  final String title;
  final String text;
  final String voiceId;
  final String engine; // 'gemini' | 'edge'
  final String filePath;
  final String ext; // 'wav' | 'mp3'
  final int createdAtMs;
  final int chunkIndex; // 1-based part number within its generation
  final int chunkCount;

  const AudioItem({
    required this.id,
    required this.title,
    required this.text,
    required this.voiceId,
    required this.engine,
    required this.filePath,
    required this.ext,
    required this.createdAtMs,
    this.chunkIndex = 1,
    this.chunkCount = 1,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'text': text,
        'voiceId': voiceId,
        'engine': engine,
        'filePath': filePath,
        'ext': ext,
        'createdAtMs': createdAtMs,
        'chunkIndex': chunkIndex,
        'chunkCount': chunkCount,
      };

  factory AudioItem.fromJson(Map<String, dynamic> json) => AudioItem(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        text: json['text'] as String? ?? '',
        voiceId: json['voiceId'] as String? ?? 'aoede',
        engine: json['engine'] as String? ?? 'gemini',
        filePath: json['filePath'] as String? ?? '',
        ext: json['ext'] as String? ?? 'wav',
        createdAtMs: json['createdAtMs'] as int? ?? 0,
        chunkIndex: json['chunkIndex'] as int? ?? 1,
        chunkCount: json['chunkCount'] as int? ?? 1,
      );

  String get displayTitle =>
      chunkCount > 1 ? '$title (part $chunkIndex/$chunkCount)' : title;
}
