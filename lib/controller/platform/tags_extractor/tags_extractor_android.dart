part of 'tags_extractor.dart';

class _TagsExtractorAndroid extends TagsExtractor {
  _TagsExtractorAndroid._init() {
    _channel = const MethodChannel('faudiotagger');
  }

  late MethodChannel _channel;
  final _ffmpegQueue = Queue(parallel: 1); // concurrent execution can result in being stuck

  Timer? _logsSetTimer;
  int _logsSetRetries = 5;
  @override
  Future<void> updateLogsPath() async {
    _logsSetTimer?.cancel();
    _logsSetRetries = 5;
    _logsSetTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      try {
        await _channel.invokeMethod("setLogFile", {"path": AppPaths.LOGS_TAGGER});
        timer.cancel();
      } catch (e) {
        _logsSetRetries--;
      }
      if (_logsSetRetries <= 0) timer.cancel();
    });
  }

  FAudioModel _getFallbackFAudioModel(String path, Map? info) {
    // since normal artworks require data to build a filename, we here fallback to filename of original path.
    final possibleFile = FileParts.join(AppDirs.ARTWORKS, '${path.getFilename}.png');
    final artwork = FArtwork(file: possibleFile, bytes: info?['artwork'] as Uint8List?);
    return FAudioModel.dummy(info?["path"] as String? ?? path, artwork);
  }

  Future<FAudioModel> _readAllData({
    required String path,
    String? artworkDirectory,
    bool extractArtwork = true,
    bool overrideArtwork = false,
  }) async {
    final map = await _channel.invokeMethod<Map<Object?, Object?>?>("readAllData", {
      "path": path,
      "artworkDirectory": artworkDirectory,
      "extractArtwork": extractArtwork,
      "overrideArtwork": overrideArtwork,
      "artworkIdentifiers": TagsExtractor.defaultGroupArtworksByAlbum ? TagsExtractor.defaultAlbumIdentifier.map((e) => e.index).toList() : null,
    });
    try {
      return FAudioModel.fromMap(map!.cast());
    } catch (e) {
      return _getFallbackFAudioModel(path, map);
    }
  }

  Future<Stream<Map<String, dynamic>>> _readAllDataAsStream({
    required int streamKey,
    required List<String> paths,
    String? artworkDirectory,
    bool extractArtwork = true,
    bool overrideArtwork = false,
  }) async {
    await _channel.invokeMethod("readAllDataAsStream", {
      "streamKey": streamKey,
      "paths": paths,
      "artworkDirectory": artworkDirectory,
      "extractArtwork": extractArtwork,
      "overrideArtwork": overrideArtwork,
      "artworkIdentifiers": TagsExtractor.defaultGroupArtworksByAlbum ? TagsExtractor.defaultAlbumIdentifier.map((e) => e.index).toList() : null,
    });
    final channelEvent = EventChannel('faudiotagger/stream/$streamKey');
    final stream = channelEvent.receiveBroadcastStream().map((event) {
      final message = event as Map<Object?, Object?>;
      final map = message.cast<String, dynamic>();
      return map;
    });
    return stream;
  }

  @override
  Future<FAudioModel> extractMetadata({
    required String trackPath,
    bool extractArtwork = true,
    String? artworkDirectory,
    Set<AlbumIdentifier>? identifiers,
    bool overrideArtwork = false,
    required bool isVideo,
    bool tagger = true,
  }) async {
    FAudioModel? trackInfo;

    if (tagger && !isVideo) {
      trackInfo = await _readAllData(
        path: trackPath,
        artworkDirectory: artworkDirectory,
        extractArtwork: extractArtwork,
        overrideArtwork: overrideArtwork,
      );
    }

    FArtwork artwork = trackInfo?.tags.artwork ?? FArtwork();
    if (extractArtwork && (artwork.file == null && artwork.bytes == null)) {
      if (artworkDirectory != null) {
        // specified directory to save in, the file is expected to exist here.
        File? artworkFile = artwork.file;
        if (artworkFile == null || !await artworkFile.exists()) {
          final identifiersSet = identifiers ?? TagsExtractor.getAlbumIdentifiersSet();
          final filename = TagsExtractor.defaultGroupArtworksByAlbum ? TagsExtractor.getArtworkIdentifierFromInfo(trackInfo, identifiersSet) : trackPath.getFilename;
          final File? thumbFile = await TagsExtractor.extractThumbnailCustom(
            trackPath: trackPath,
            filename: filename,
            artworkDirectory: artworkDirectory,
            isVideo: isVideo,
          );
          artwork.file = thumbFile;
        }
      } else {
        // -- otherwise the artwork should be within info as bytes.
        Uint8List? artworkBytes = artwork.bytes;
        if (artworkBytes == null || artworkBytes.isEmpty) {
          final File? tempFile = await TagsExtractor.extractThumbnailCustom(
            trackPath: trackPath,
            filename: null,
            artworkDirectory: null,
            isVideo: isVideo,
          );
          artwork.bytes = await tempFile?.readAsBytes();
          tempFile?.tryDeleting();
        }
      }
    }

    if (trackInfo == null || trackInfo.hasError) {
      final ffmpegInfo = await _ffmpegQueue.add(() => ffmpegController.extractMetadata(trackPath).timeout(const Duration(seconds: 5)).catchError((_) => null));

      if (ffmpegInfo != null && isVideo) {
        try {
          final stats = File(trackPath).statSync();
          videoController.addLocalVideoFileInfoToCacheMap(trackPath, ffmpegInfo, stats);
        } catch (_) {}
      }
      trackInfo = ffmpegInfo == null ? FAudioModel.dummy(trackPath, artwork) : ffmpegInfo.toFAudioModel(artwork: artwork);
    }

    return trackInfo;
  }

  @override
  Future<Stream<FAudioModel>> extractMetadataAsStream({
    required List<String> paths,
    bool extractArtwork = true,
    String? artworkDirectory,
    bool overrideArtwork = false,
  }) async {
    final streamKey = DateTime.now().microsecondsSinceEpoch;
    final identifiersSet = TagsExtractor.getAlbumIdentifiersSet();
    final initialStream = await _readAllDataAsStream(
      streamKey: streamKey,
      paths: paths,
      extractArtwork: extractArtwork,
      artworkDirectory: artworkDirectory,
      overrideArtwork: overrideArtwork,
    );
    StreamSubscription<dynamic>? streamSub;
    final usingStream = Completer<void>();
    int toExtract = paths.length;

    _streamControllers[streamKey] = StreamController<FAudioModel>();
    final streamController = _streamControllers[streamKey]!;

    Future<void> closeStreams() async {
      await usingStream.future;
      streamController.close();
      streamSub?.cancel();
      _streamControllers.remove(streamKey);
      currentPathsBeingExtracted.remove(streamKey);
    }

    int extractingCount = 0;
    void incrementCurrentExtracting() {
      if (paths.isEmpty) return;
      try {
        extractingCount++;
        currentPathsBeingExtracted[streamKey] = paths[extractingCount];
      } catch (_) {}
    }

    void onExtract(FAudioModel info) {
      streamController.add(info);
      toExtract--;
      incrementCurrentExtracting();
      if (toExtract <= 0) {
        usingStream.completeIfWasnt();
        closeStreams();
      }
    }

    // currentPathsBeingExtracted[streamKey] = paths[0];

    streamSub = initialStream.listen(
      (map) {
        final path = map['path'] as String;
        if (map["ERROR_FAULTY"] == true) {
          extractMetadata(
            trackPath: path,
            tagger: false,
            identifiers: identifiersSet,
            extractArtwork: extractArtwork,
            overrideArtwork: overrideArtwork,
            isVideo: path.isVideo(),
          ).then(onExtract);
        } else {
          try {
            onExtract(FAudioModel.fromMap(map));
          } catch (e) {
            onExtract(_getFallbackFAudioModel(path, map));
          }
        }
      },
      onDone: closeStreams,
      onError: (e) => closeStreams(),
    );
    _channel.invokeMethod("streamReady", {"streamKey": streamKey, "count": paths.length}); // we ready to recieve
    return streamController.stream;
  }

  Future<String?> _writeTagsInternal({
    required String path,
    required FTags tags,
  }) async {
    try {
      return await _channel.invokeMethod<String?>("writeTags", {
        "path": path,
        "tags": tags.toMap(),
      });
    } catch (e) {
      return e.toString();
    }
  }

  @override
  Future<bool> writeTags({
    required String path,
    required FTags newTags,
    required String? commentToInsert,
    required String? oldComment,
  }) async {
    // -- 1. try tagger
    String? error = await _writeTagsInternal(
      path: path,
      tags: newTags,
    );

    bool didUpdate = error == null || error == '';

    if (!didUpdate) {
      // -- 2. try with ffmpeg
      final ffmpegTagsMap = commentToInsert != null && commentToInsert.isNotEmpty
          ? <String, String?>{
              FFMPEGTagField.comment: oldComment == null || oldComment.isEmpty ? commentToInsert : '$commentToInsert\n$oldComment',
            }
          : <String, String?>{
              FFMPEGTagField.title: newTags.title,
              FFMPEGTagField.artist: newTags.artist,
              FFMPEGTagField.album: newTags.album,
              FFMPEGTagField.albumArtist: newTags.albumArtist,
              FFMPEGTagField.composer: newTags.composer,
              FFMPEGTagField.genre: newTags.genre,
              FFMPEGTagField.year: newTags.year,
              FFMPEGTagField.trackNumber: newTags.trackNumber,
              FFMPEGTagField.discNumber: newTags.discNumber,
              FFMPEGTagField.trackTotal: newTags.trackTotal,
              FFMPEGTagField.discTotal: newTags.discTotal,
              FFMPEGTagField.comment: newTags.comment,
              FFMPEGTagField.description: newTags.description,
              FFMPEGTagField.synopsis: newTags.synopsis,
              FFMPEGTagField.lyrics: newTags.lyrics,
              FFMPEGTagField.remixer: newTags.remixer,
              FFMPEGTagField.lyricist: newTags.lyricist,
              FFMPEGTagField.language: newTags.language,
              FFMPEGTagField.recordLabel: newTags.recordLabel,
              FFMPEGTagField.country: newTags.country,

              // -- TESTED NOT WORKING. disabling to prevent unwanted fields corruption etc.
              // FFMPEGTagField.mood: editedTags[TagField.mood],
              // FFMPEGTagField.tags: editedTags[TagField.tags],
              // FFMPEGTagField.rating: editedTags[TagField.rating],
            };
      didUpdate = await ffmpegController.editMetadata(
        path: path,
        tagsMap: ffmpegTagsMap,
      );

      final imageFile = newTags.artwork.file;
      if (imageFile != null) {
        await ffmpegController.editAudioThumbnail(audioPath: path, thumbnailPath: imageFile.path);
      }
      snackyy(
        title: lang.WARNING,
        message: 'FFMPEG was used. Some tags might not have been updated',
        isError: true,
      );
    }
    return didUpdate;
  }
}