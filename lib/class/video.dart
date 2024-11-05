import 'dart:io';

import 'package:namida/class/folder.dart';
import 'package:namida/class/track.dart';
import 'package:namida/core/constants.dart';
import 'package:namida/core/extensions.dart';

/// used for stats.
class YoutubeVideoHistory {
  final String id;
  final String title;
  final String channel;
  final String channelUrl;
  final List<YTWatch> watches;

  const YoutubeVideoHistory({
    required this.id,
    required this.title,
    required this.channel,
    required this.channelUrl,
    required this.watches,
  });

  factory YoutubeVideoHistory.fromJson(Map<String, dynamic> json) {
    return YoutubeVideoHistory(
      id: json['id'] ?? '',
      title: json['title'] ?? '',
      channel: json['channel'] ?? '',
      channelUrl: json['channelUrl'] ?? '',
      watches: (json['watches'] as List?)?.map((e) => YTWatch.fromJson(e)).toList() ?? [],
    );
  }

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> data = <String, dynamic>{};
    data['id'] = id;
    data['title'] = title;
    data['channel'] = channel;
    data['channelUrl'] = channelUrl;
    data['watches'] = watches;
    return data;
  }
}

class YTWatch {
  final DateTime? dateNull;
  final bool isYTMusic;

  DateTime get date => _date;
  DateTime get _date => dateNull ?? DateTime.now();

  const YTWatch({
    required this.dateNull,
    required this.isYTMusic,
  });

  factory YTWatch.fromJson(Map<String, dynamic>? json) {
    if (json == null) {
      return YTWatch(dateNull: DateTime(1970), isYTMusic: false);
    }
    return YTWatch(
      dateNull: DateTime.fromMillisecondsSinceEpoch(json['date'] ?? 0),
      isYTMusic: json['isYTMusic'] ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'date': _date.millisecondsSinceEpoch,
      'isYTMusic': isYTMusic,
    };
  }

  @override
  bool operator ==(covariant YTWatch other) {
    if (identical(this, other)) return true;
    return other.dateNull == dateNull && other.isYTMusic == isYTMusic;
  }

  @override
  int get hashCode => dateNull.hashCode ^ isYTMusic.hashCode;
}

class NamidaVideo {
  int get resolution => width < height ? width : height;
  final String path;
  final String? ytID;
  final String? nameInCache;
  final int height;
  final int width;
  final int sizeInBytes;
  final double frameratePrecise;
  final int creationTimeMS;
  final int durationMS;
  final int bitrate;

  const NamidaVideo({
    required this.path,
    this.ytID,
    this.nameInCache,
    required this.height,
    required this.width,
    required this.sizeInBytes,
    required this.frameratePrecise,
    required this.creationTimeMS,
    required this.durationMS,
    required this.bitrate,
  });

  factory NamidaVideo.fromJson(Map<String, dynamic> json) {
    final youtubeId = json['ytID'] as String?;
    final path = json['path'] as String?;
    return NamidaVideo(
      path: path ?? '',
      ytID: youtubeId,
      nameInCache: json['nameInCache'] ?? (youtubeId != null ? path?.getFilenameWOExt : null),
      height: json['height'] ?? 0,
      width: json['width'] ?? 0,
      sizeInBytes: json['sizeInBytes'] ?? 0,
      frameratePrecise: json['frameratePrecise'] ?? 0.0,
      creationTimeMS: json['creationTimeMS'] ?? 0,
      durationMS: json['durationMS'] ?? 0,
      bitrate: json['bitrate'] ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'path': path,
      'ytID': ytID,
      'nameInCache': nameInCache,
      'height': height,
      'width': width,
      'sizeInBytes': sizeInBytes,
      'frameratePrecise': frameratePrecise,
      'creationTimeMS': creationTimeMS,
      'durationMS': durationMS,
      'bitrate': bitrate,
    };
  }

  @override
  bool operator ==(covariant NamidaVideo other) {
    return path == other.path &&
        ytID == other.ytID &&
        height == other.height &&
        width == other.width &&
        sizeInBytes == other.sizeInBytes &&
        frameratePrecise == other.frameratePrecise &&
        creationTimeMS == other.creationTimeMS;
  }

  @override
  int get hashCode => "$path$ytID$height$width$sizeInBytes$frameratePrecise$creationTimeMS".hashCode;

  @override
  String toString() {
    return toJson().toString();
  }
}

extension NamidaVideoUtils on NamidaVideo {
  String framerateText([int displayAbove = 30]) {
    final videoFramerate = framerate;
    return videoFramerate > displayAbove ? videoFramerate.toString() : '';
  }

  int get framerate => frameratePrecise.round();

  String get pathToImage {
    final isLocal = ytID == null;
    final dir = isLocal ? AppDirs.THUMBNAILS : AppDirs.YT_THUMBNAILS;
    final idOrFileNameWOExt = ytID ?? path.getFilenameWOExt;

    String getPath(String prefix) => "$dir$prefix$idOrFileNameWOExt.png";

    if (!isLocal) {
      final path = getPath('');
      if (File(path).existsSync()) {
        return path;
      }
    }
    return getPath('EXT_');
  }
}

class Video extends Track {
  @override
  VideoFolder get folder => VideoFolder.explicit(folderPath);

  @override
  Track get track => this;

  const Video.explicit(super.path) : super.explicit();
}

extension VideoUtils on Video {
  VideoFolder get folder => VideoFolder.explicit(folderPath);
}
