import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../core/package_manifest.dart';
import '../core/playlist_plan.dart';
import '../domain/radio_library.dart';
import 'studio_state.dart';

enum PlaylistCatalogView { package, game }

enum PlaylistCatalogOrigin { package, game, failed }

@immutable
class PlaylistCatalog {
  const PlaylistCatalog({
    this.view = PlaylistCatalogView.package,
    required this.origin,
    required this.sourcePath,
    required this.radios,
    required this.modes,
    required this.freeRoamTracks,
    required this.eventTracks,
    this.listModes = const {},
    this.sourceBySoundName = const {},
    this.error,
  });

  factory PlaylistCatalog.failed({
    required PlaylistCatalogView view,
    required String? packageDir,
    required String gameDir,
  }) {
    final checked = [
      if (view == PlaylistCatalogView.package &&
          packageDir != null &&
          packageDir.trim().isNotEmpty)
        '准备包：$packageDir',
      if (gameDir.trim().isNotEmpty) '游戏目录：$gameDir',
    ].join('\n');
    return PlaylistCatalog(
      view: view,
      origin: PlaylistCatalogOrigin.failed,
      sourcePath: null,
      radios: const [],
      modes: const {},
      freeRoamTracks: const {},
      eventTracks: const {},
      listModes: const {},
      sourceBySoundName: const {},
      error: checked.isEmpty
          ? '没有找到可读取的 RadioInfo_*.xml。请先在 Dashboard 设置 FH6 安装目录，或生成准备包后再打开播放列表。'
          : '没有找到可读取的 RadioInfo_*.xml。已检查：\n$checked',
    );
  }

  final PlaylistCatalogView view;
  final PlaylistCatalogOrigin origin;
  final String? sourcePath;
  final List<RadioStation> radios;
  final Map<String, StationMode> modes;
  final Map<String, List<TrackRef>> freeRoamTracks;
  final Map<String, List<TrackRef>> eventTracks;
  final Map<String, Map<String, StationMode>> listModes;
  final Map<String, String> sourceBySoundName;
  final String? error;

  bool get failed => origin == PlaylistCatalogOrigin.failed;

  String get badgeLabel {
    return switch (origin) {
      PlaylistCatalogOrigin.package => '当前准备包',
      PlaylistCatalogOrigin.game when view == PlaylistCatalogView.package =>
        '从游戏内初始化',
      PlaylistCatalogOrigin.game => '当前游戏内',
      PlaylistCatalogOrigin.failed => '读取失败',
    };
  }

  String get badgeTooltip {
    return switch (origin) {
      PlaylistCatalogOrigin.package => '正在读取最新准备包里的 RadioInfo。',
      PlaylistCatalogOrigin.game when view == PlaylistCatalogView.package =>
        '未找到可读取的准备包，当前用游戏内排布作为初始化基底。',
      PlaylistCatalogOrigin.game => '正在查看游戏内当前 RadioInfo。',
      PlaylistCatalogOrigin.failed => '没有找到可读取的 RadioInfo。',
    };
  }

  StationMode modeOf(String radioCode) {
    return modes[radioCode] ?? StationMode.builtin;
  }

  StationMode modeOfList(String radioCode, String playlistType) {
    final type = PlaylistAssignment.normalizePlaylistType(playlistType);
    return listModes[radioCode]?[type] ?? modeOf(radioCode);
  }

  List<TrackRef> tracksOfRadio(String radioCode, String playlistType) {
    final primary = playlistType == 'Event' ? eventTracks : freeRoamTracks;
    final fallback = playlistType == 'Event' ? freeRoamTracks : eventTracks;
    return primary[radioCode] ?? fallback[radioCode] ?? const <TrackRef>[];
  }

  String? sourceForTrack(TrackRef track) {
    final sound = track.soundName?.trim();
    if (sound == null || sound.isEmpty) return null;
    return sourceBySoundName[sound];
  }
}

final playlistCatalogViewProvider = StateProvider<PlaylistCatalogView>(
  (ref) => PlaylistCatalogView.package,
);

final playlistCatalogProvider = Provider<PlaylistCatalog>((ref) {
  final view = ref.watch(playlistCatalogViewProvider);
  return ref.watch(playlistCatalogForViewProvider(view));
});

final gamePlaylistCatalogProvider = Provider<PlaylistCatalog>((ref) {
  return ref.watch(playlistCatalogForViewProvider(PlaylistCatalogView.game));
});

final playlistCatalogForViewProvider =
    Provider.family<PlaylistCatalog, PlaylistCatalogView>((ref, view) {
      final state = ref.watch(
        studioProvider.select(
          (state) => (
            packageDir: state.pendingPackageReady
                ? state.pendingPackageDir
                : state.lastPackageDir,
            pendingPackageDir: state.pendingPackageReady
                ? state.pendingPackageDir
                : null,
            lastPackageDir: state.lastPackageDir,
            gameDir: state.gameDir,
            sourceLang: state.sourceLang,
            targetLang: state.targetLang,
            bankSlotOverrides: {
              for (final option in state.radioOptions)
                if (option.bankSlots != null && option.bankSlots! > 0)
                  _radioCodeFor(option.number, option.name): option.bankSlots!,
            },
          ),
        ),
      );
      return loadPlaylistCatalog(
        view: view,
        packageDir: state.packageDir,
        gameDir: state.gameDir,
        sourceLang: state.sourceLang,
        targetLang: state.targetLang,
        detectionPackageDirs: [state.pendingPackageDir, state.lastPackageDir],
        bankSlotOverrides: state.bankSlotOverrides,
      );
    });

@visibleForTesting
PlaylistCatalog loadPlaylistCatalog({
  PlaylistCatalogView view = PlaylistCatalogView.package,
  required String? packageDir,
  required String gameDir,
  required String sourceLang,
  required String targetLang,
  Iterable<String?> detectionPackageDirs = const [],
  Map<String, int> bankSlotOverrides = const {},
}) {
  final detectionManifests = [
    for (final dir in detectionPackageDirs) readPackageManifest(dir),
  ].whereType<Map<String, dynamic>>().toList(growable: false);
  final gameAudio = _gameAudioDir(gameDir);

  if (view == PlaylistCatalogView.game) {
    final gameXml = _radioInfoFile(gameAudio, sourceLang, targetLang);
    if (gameXml != null) {
      final catalog = _readXmlCatalog(
        gameXml,
        view: view,
        origin: PlaylistCatalogOrigin.game,
        detectionPackageManifests: detectionManifests,
        bankSlotOverrides: bankSlotOverrides,
      );
      if (catalog != null) return catalog;
    }
    return PlaylistCatalog.failed(
      view: view,
      packageDir: null,
      gameDir: gameDir,
    );
  }

  final packageAudio = _packageAudioDir(packageDir);
  final packageXml = _radioInfoFile(packageAudio, sourceLang, targetLang);
  if (packageXml != null) {
    final manifest = readPackageManifest(packageDir);
    final catalog = _readXmlCatalog(
      packageXml,
      view: view,
      origin: PlaylistCatalogOrigin.package,
      packageManifest: manifest,
      detectionPackageManifests: [?manifest, ...detectionManifests],
      bankSlotOverrides: bankSlotOverrides,
      bankAudioFallback: gameAudio,
    );
    if (catalog != null) return catalog;
  }

  final gameXml = _radioInfoFile(gameAudio, sourceLang, targetLang);
  if (gameXml != null) {
    final catalog = _readXmlCatalog(
      gameXml,
      view: view,
      origin: PlaylistCatalogOrigin.game,
      detectionPackageManifests: detectionManifests,
      bankSlotOverrides: bankSlotOverrides,
    );
    if (catalog != null) return catalog;
  }

  return PlaylistCatalog.failed(
    view: view,
    packageDir: packageDir,
    gameDir: gameDir,
  );
}

PlaylistCatalog? _readXmlCatalog(
  File xmlFile, {
  required PlaylistCatalogView view,
  required PlaylistCatalogOrigin origin,
  Map<String, dynamic>? packageManifest,
  Iterable<Map<String, dynamic>> detectionPackageManifests = const [],
  Map<String, int> bankSlotOverrides = const {},
  Directory? bankAudioFallback,
}) {
  try {
    final document = XmlDocument.parse(
      xmlFile.readAsStringSync(encoding: utf8),
    );
    final packageRadio = _objectInt(packageManifest?['radio']);
    final packageSounds = <String>{};
    final sourceBySoundName = <String, String>{};
    for (final manifest in detectionPackageManifests) {
      packageSounds.addAll(_packagePlaylistSoundNames(manifest));
      sourceBySoundName.addAll(_packagePlaylistSourcesBySoundName(manifest));
    }
    if (packageManifest != null) {
      packageSounds.addAll(_packagePlaylistSoundNames(packageManifest));
      sourceBySoundName.addAll(
        _packagePlaylistSourcesBySoundName(packageManifest),
      );
    }
    final radios = <RadioStation>[];
    final modes = <String, StationMode>{};
    final listModes = <String, Map<String, StationMode>>{};
    final freeRoamTracks = <String, List<TrackRef>>{};
    final eventTracks = <String, List<TrackRef>>{};

    for (final station in document.findAllElements('RadioStation')) {
      final number = _objectInt(station.getAttribute('Number'));
      final name = station.getAttribute('Name')?.trim() ?? '';
      final code = _radioCodeFor(number, name);
      final samples = _samplesBySoundName(station, code, packageSounds);
      final freeRoam = _playlistTracks(station, 'FreeRoam', samples, code);
      final event = _playlistTracks(station, 'Event', samples, code);
      final xmlSlot = math.max(
        samples.length,
        math.max(freeRoam.length, event.length),
      );
      final bankSlot =
          bankSlotOverrides[code] ??
          _trackBankSlots(station, xmlFile.parent, number) ??
          _trackBankSlotsFromFallback(
            station,
            xmlFile.parent,
            bankAudioFallback,
            number,
          );
      radios.add(
        RadioStation(
          code: code,
          name: name.isEmpty ? code : name,
          hue: _radioHue(code),
          genre: _radioGenre(code, number),
          slot: math.max(bankSlot ?? xmlSlot, 1),
        ),
      );
      freeRoamTracks[code] = freeRoam.isEmpty
          ? samples.values.toList(growable: false)
          : freeRoam;
      eventTracks[code] = event.isEmpty
          ? freeRoamTracks[code] ?? samples.values.toList(growable: false)
          : event;

      final freeMode = _tracksContainModded(freeRoamTracks[code])
          ? StationMode.custom
          : StationMode.builtin;
      final eventMode = _tracksContainModded(eventTracks[code])
          ? StationMode.custom
          : StationMode.builtin;
      listModes[code] = {'FreeRoam': freeMode, 'Event': eventMode};
      final isPackageRadio =
          origin == PlaylistCatalogOrigin.package &&
          packageRadio != null &&
          number == packageRadio;
      modes[code] =
          freeMode == StationMode.custom ||
              eventMode == StationMode.custom ||
              isPackageRadio
          ? StationMode.custom
          : StationMode.builtin;
    }

    if (radios.isEmpty) return null;
    radios.sort(
      (a, b) => _radioSortKey(a.code).compareTo(_radioSortKey(b.code)),
    );
    return PlaylistCatalog(
      view: view,
      origin: origin,
      sourcePath: xmlFile.path,
      radios: radios,
      modes: modes,
      freeRoamTracks: freeRoamTracks,
      eventTracks: eventTracks,
      listModes: listModes,
      sourceBySoundName: sourceBySoundName,
    );
  } on FormatException {
    return null;
  } on FileSystemException {
    return null;
  }
}

Directory? _packageAudioDir(String? packageDir) {
  if (packageDir == null || packageDir.trim().isEmpty) return null;
  final root = Directory(packageDir);
  final candidates = [
    Directory(p.join(root.path, 'package', 'media', 'audio')),
    Directory(p.join(root.path, 'media', 'audio')),
    if (p.basename(root.path).toLowerCase() == 'audio') root,
  ];
  return candidates.firstWhereOrNull((dir) => dir.existsSync());
}

Directory? _gameAudioDir(String gameDir) {
  if (gameDir.trim().isEmpty) return null;
  final root = Directory(gameDir);
  final candidates = [
    Directory(p.join(root.path, 'media', 'audio')),
    if (p.basename(root.path).toLowerCase() == 'audio') root,
  ];
  return candidates.firstWhereOrNull((dir) => dir.existsSync());
}

File? _radioInfoFile(
  Directory? audioDir,
  String sourceLang,
  String targetLang,
) {
  if (audioDir == null || !audioDir.existsSync()) return null;
  final candidates = [sourceLang, targetLang, 'EN', 'GB', 'CHS', 'CN']
      .map((lang) => lang.trim().toUpperCase())
      .where((lang) => lang.isNotEmpty)
      .toSet()
      .map((lang) => File(p.join(audioDir.path, 'RadioInfo_$lang.xml')));
  for (final file in candidates) {
    if (file.existsSync()) return file;
  }
  final files =
      audioDir
          .listSync(followLinks: false)
          .whereType<File>()
          .where((file) => p.basename(file.path).startsWith('RadioInfo_'))
          .toList()
        ..sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
  return files.firstOrNull;
}

const _trackBankSuffixPreference = ['CU1', 'CU2', 'Disk', 'PDLC1', 'PDLC2'];
const _fsb5HeaderSize = 60;
const _fsb5MaxSamples = 4096;
const _maxFsb5ScanBytes = 16 * 1024 * 1024;

int? _trackBankSlots(XmlElement station, Directory audioDir, int? radioNumber) {
  final fmodDir = Directory(p.join(audioDir.path, 'FMODBanks'));
  final names = <String>[];
  final seen = <String>{};

  void addName(String raw) {
    final name = raw.trim();
    if (name.isEmpty || !name.contains('Tracks')) return;
    if (seen.add(name)) names.add(name);
  }

  final banks = station.findElements('Banks').firstOrNull;
  if (banks != null) {
    for (final bank in banks.findElements('Bank')) {
      addName(bank.getAttribute('Name') ?? '');
    }
  }

  if (radioNumber != null && radioNumber > 0 && fmodDir.existsSync()) {
    final prefix = 'R${radioNumber}_Tracks_';
    final files = fmodDir.listSync(followLinks: false).whereType<File>().where((
      file,
    ) {
      final name = p.basename(file.path);
      return name.startsWith(prefix) && name.endsWith('.assets.bank');
    }).toList()..sort((a, b) => a.path.compareTo(b.path));
    for (final file in files) {
      addName(_bankNameFromPath(file.path));
    }
  }

  final parsed = [
    for (final name in names)
      (
        name: name,
        slots: _parseFsb5SampleCount(_bankPathForName(fmodDir, name)),
      ),
  ].where((item) => item.slots != null && item.slots! > 0).toList();
  if (parsed.isEmpty) return null;

  for (final suffix in _trackBankSuffixPreference) {
    final preferred = parsed.firstWhereOrNull(
      (item) => item.name.endsWith('_$suffix'),
    );
    if (preferred != null) return preferred.slots;
  }
  return parsed.first.slots;
}

int? _trackBankSlotsFromFallback(
  XmlElement station,
  Directory primaryAudioDir,
  Directory? fallbackAudioDir,
  int? radioNumber,
) {
  if (fallbackAudioDir == null) return null;
  if (p.equals(primaryAudioDir.path, fallbackAudioDir.path)) return null;
  return _trackBankSlots(station, fallbackAudioDir, radioNumber);
}

File _bankPathForName(Directory fmodDir, String name) {
  final filename = name.endsWith('.assets.bank') ? name : '$name.assets.bank';
  return File(p.join(fmodDir.path, filename));
}

String _bankNameFromPath(String path) {
  final filename = p.basename(path);
  const suffix = '.assets.bank';
  if (filename.endsWith(suffix)) {
    return filename.substring(0, filename.length - suffix.length);
  }
  return p.basenameWithoutExtension(filename);
}

int? _parseFsb5SampleCount(File file) {
  if (!file.existsSync()) return null;
  RandomAccessFile? handle;
  try {
    handle = file.openSync();
    final length = file.lengthSync();
    final scanLimit = math.min(length, _maxFsb5ScanBytes);
    const chunkSize = 64 * 1024;
    var position = 0;
    var previous = Uint8List(0);

    while (position < scanLimit) {
      final chunk = handle.readSync(math.min(chunkSize, scanLimit - position));
      if (chunk.isEmpty) break;
      final scan = Uint8List(previous.length + chunk.length)
        ..setRange(0, previous.length, previous)
        ..setRange(previous.length, previous.length + chunk.length, chunk);
      final scanBase = position - previous.length;
      final index = _indexOfFsb5(scan);
      if (index >= 0) {
        final fsbOffset = scanBase + index;
        if (fsbOffset + _fsb5HeaderSize > length) return null;
        handle.setPositionSync(fsbOffset);
        final header = handle.readSync(_fsb5HeaderSize);
        if (header.length < _fsb5HeaderSize) return null;
        final view = ByteData.sublistView(header);
        final samples = view.getUint32(8, Endian.little);
        if (samples <= 0 || samples > _fsb5MaxSamples) return null;
        return samples;
      }
      previous = _tail(scan, _fsb5HeaderSize - 1);
      position += chunk.length;
    }
  } on FileSystemException {
    return null;
  } on RangeError {
    return null;
  } finally {
    handle?.closeSync();
  }
  return null;
}

int _indexOfFsb5(Uint8List bytes) {
  for (var i = 0; i <= bytes.length - 4; i += 1) {
    if (bytes[i] == 0x46 &&
        bytes[i + 1] == 0x53 &&
        bytes[i + 2] == 0x42 &&
        bytes[i + 3] == 0x35) {
      return i;
    }
  }
  return -1;
}

Uint8List _tail(Uint8List bytes, int length) {
  if (bytes.length <= length) return Uint8List.fromList(bytes);
  return Uint8List.sublistView(bytes, bytes.length - length);
}

Map<String, TrackRef> _samplesBySoundName(
  XmlElement station,
  String code,
  Set<String> customSounds,
) {
  final trackList = station
      .findElements('SampleList')
      .firstWhereOrNull((node) => node.getAttribute('Type') == 'Track');
  if (trackList == null) return const {};
  final out = <String, TrackRef>{};
  var index = 0;
  for (final sample in trackList.findElements('Sample')) {
    index++;
    final soundName = sample.getAttribute('SoundName')?.trim();
    if (soundName == null || soundName.isEmpty) continue;
    final title = sample.getAttribute('DisplayName')?.trim();
    final artist = sample.getAttribute('Artist')?.trim();
    out[soundName] = TrackRef(
      id: '$code-$index-$soundName',
      title: title == null || title.isEmpty ? soundName : title,
      artist: artist == null || artist.isEmpty ? 'Unknown Artist' : artist,
      durationSec: _sampleDuration(sample),
      soundName: soundName,
      modded: customSounds.contains(soundName),
    );
  }
  return out;
}

List<TrackRef> _playlistTracks(
  XmlElement station,
  String type,
  Map<String, TrackRef> samples,
  String code,
) {
  final playlist = station
      .findElements('PlayList')
      .firstWhereOrNull((node) => node.getAttribute('Type') == type);
  if (playlist == null) return const [];
  final out = <TrackRef>[];
  var index = 0;
  for (final entry in playlist.findElements('Entry')) {
    final soundName = entry.getAttribute('Name')?.trim();
    if (soundName == null || soundName.isEmpty) continue;
    out.add(
      samples[soundName] ??
          TrackRef(
            id: '$code-$type-$index-$soundName',
            title: soundName,
            artist: 'Unknown Artist',
            durationSec: 0,
            soundName: soundName,
          ),
    );
    index++;
  }
  return out;
}

double _sampleDuration(XmlElement sample) {
  final length =
      double.tryParse(sample.getAttribute('SampleLength') ?? '') ?? 0;
  final rate = double.tryParse(sample.getAttribute('SampleRate') ?? '') ?? 0;
  if (length <= 0 || rate <= 0) return 0;
  return length / rate;
}

Set<String> _packagePlaylistSoundNames(Map<String, dynamic>? manifest) {
  final out = <String>{};
  void addFrom(Object? items) {
    if (items is! List) return;
    for (final item in items) {
      if (item is! Map) continue;
      if (item['playlist_entry'] != true) continue;
      final soundName = '${item['target_sound_name'] ?? ''}'.trim();
      if (soundName.isNotEmpty) out.add(soundName);
    }
  }

  final radios = manifest?['radios'];
  if (radios is List) {
    for (final radio in radios) {
      if (radio is Map) addFrom(radio['assignments']);
    }
  }
  return out;
}

Map<String, String> _packagePlaylistSourcesBySoundName(
  Map<String, dynamic>? manifest,
) {
  final out = <String, String>{};
  void addFrom(Object? items) {
    if (items is! List) return;
    for (final item in items) {
      if (item is! Map) continue;
      if (item['playlist_entry'] != true) continue;
      final soundName = '${item['target_sound_name'] ?? ''}'.trim();
      final source = '${item['source'] ?? ''}'.trim();
      if (soundName.isNotEmpty && source.isNotEmpty) {
        out[soundName] = source;
      }
    }
  }

  final radios = manifest?['radios'];
  if (radios is List) {
    for (final radio in radios) {
      if (radio is Map) addFrom(radio['assignments']);
    }
  }
  return out;
}

bool _tracksContainModded(List<TrackRef>? tracks) {
  return tracks?.any((track) => track.modded) ?? false;
}

String _radioCodeFor(int? number, String station) {
  final normalized = station.toLowerCase();
  if (normalized.contains('horizon pulse')) return 'HOR';
  if (normalized.contains('bass arena')) return 'BAS';
  if (normalized.contains('block party')) return 'BLK';
  if (normalized.contains('eurobeat')) return 'EUR';
  if (normalized.contains('rocas')) return 'ROC';
  if (normalized == 'xs' || normalized.contains('horizon xs')) return 'XS';
  if (normalized.contains('timeless')) return 'TIM';
  if (normalized.contains('mixmaster')) return 'MIX';
  if (number != null) return 'R$number';
  return station.trim().isEmpty ? 'R?' : station.trim();
}

String _radioHue(String code) {
  return kRadios.firstWhereOrNull((radio) => radio.code == code)?.hue ?? 'cyan';
}

String _radioGenre(String code, int? number) {
  final known = kRadios.firstWhereOrNull((radio) => radio.code == code)?.genre;
  if (known != null) return known;
  return number == null ? '电台' : 'R$number';
}

int _radioSortKey(String code) {
  final index = kRadios.indexWhere((radio) => radio.code == code);
  if (index >= 0) return index;
  final number = int.tryParse(code.replaceFirst(RegExp(r'^R'), ''));
  return number == null ? 1000 : 100 + number;
}

int? _objectInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.round();
  if (value is String) return int.tryParse(value);
  return null;
}
