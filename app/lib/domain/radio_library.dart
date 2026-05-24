// FH Radio Studio domain models and bundled seed data.
//
// 数据类名加 `Station` / `Ref` 后缀避免与 Flutter Material 自带类（Radio 等）冲突。

class RadioStation {
  const RadioStation({
    required this.code,
    required this.name,
    required this.hue,
    required this.genre,
    required this.slot,
  });

  final String code;
  final String name;
  final String hue; // lime/cyan/orange/magenta/red/violet/yellow/teal
  final String genre;
  final int slot;
}

enum StationMode { builtin, custom }

class TrackRef {
  const TrackRef({
    required this.id,
    required this.title,
    required this.artist,
    required this.durationSec,
    this.soundName,
    this.modded = false,
  });

  final String id;
  final String title;
  final String artist;
  final double durationSec;
  final String? soundName;
  final bool modded;
}

class PoolTrack {
  const PoolTrack({
    required this.id,
    required this.title,
    required this.artist,
    required this.source,
    required this.durationSec,
    required this.bpm,
    required this.key,
    required this.configured,
    required this.confirmed,
    this.sampleRate,
    this.channels,
    this.samples,
    this.assignedTo,
    this.slot,
    this.sourceKind = 'local',
    this.sourceLabel,
    this.sirenCid,
    this.albumName,
    this.coverUrl,
    this.coverArtPath,
    required this.added,
  });

  final String id;
  final String title;
  final String artist;
  final String source;
  final double durationSec;
  final int bpm;
  final String key;
  final bool configured;
  final int confirmed; // 0..4 — 已确认的 time group 数
  final int? sampleRate;
  final int? channels;
  final int? samples;
  final String? assignedTo;
  final int? slot;
  final String sourceKind;
  final String? sourceLabel;
  final String? sirenCid;
  final String? albumName;
  final String? coverUrl;
  final String? coverArtPath;
  final String added;

  bool get isSiren => sourceKind == 'siren';

  PoolTrack copyWith({
    String? assignedTo,
    int? slot,
    bool clearAssigned = false,
  }) {
    return PoolTrack(
      id: id,
      title: title,
      artist: artist,
      source: source,
      durationSec: durationSec,
      bpm: bpm,
      key: key,
      configured: configured,
      confirmed: confirmed,
      sampleRate: sampleRate,
      channels: channels,
      samples: samples,
      assignedTo: clearAssigned ? null : (assignedTo ?? this.assignedTo),
      slot: clearAssigned ? null : (slot ?? this.slot),
      sourceKind: sourceKind,
      sourceLabel: sourceLabel,
      sirenCid: sirenCid,
      albumName: albumName,
      coverUrl: coverUrl,
      coverArtPath: coverArtPath,
      added: added,
    );
  }
}

class RecentProject {
  const RecentProject({
    required this.name,
    required this.path,
    required this.when,
    required this.game,
  });

  final String name;
  final String path;
  final String when;
  final String game;
}

// ============================================================
// RADIOS — 8 个电台
// ============================================================
const List<RadioStation> kRadios = [
  RadioStation(
    code: 'HOR',
    name: 'Horizon Pulse',
    hue: 'lime',
    genre: '电子 / 节拍',
    slot: 8,
  ),
  RadioStation(
    code: 'BAS',
    name: 'Bass Arena',
    hue: 'magenta',
    genre: 'Bass / DnB',
    slot: 6,
  ),
  RadioStation(
    code: 'BLK',
    name: 'Block Party',
    hue: 'orange',
    genre: 'Hip-hop',
    slot: 6,
  ),
  RadioStation(
    code: 'EUR',
    name: 'Eurobeat Express',
    hue: 'cyan',
    genre: 'Eurobeat',
    slot: 4,
  ),
  RadioStation(
    code: 'ROC',
    name: 'Rocas Negras',
    hue: 'red',
    genre: 'Latin / Rock',
    slot: 6,
  ),
  RadioStation(
    code: 'XS',
    name: 'XS',
    hue: 'violet',
    genre: 'Metal / Rock',
    slot: 6,
  ),
  RadioStation(
    code: 'TIM',
    name: 'Timeless FM',
    hue: 'yellow',
    genre: 'Classics',
    slot: 8,
  ),
  RadioStation(
    code: 'MIX',
    name: 'Mixmaster',
    hue: 'teal',
    genre: 'DJ Mix',
    slot: 4,
  ),
];

const Map<String, StationMode> kStationModes = {
  'HOR': StationMode.custom,
  'BAS': StationMode.builtin,
  'BLK': StationMode.custom,
  'EUR': StationMode.builtin,
  'ROC': StationMode.builtin,
  'XS': StationMode.builtin,
  'TIM': StationMode.builtin,
  'MIX': StationMode.builtin,
};

// ============================================================
// TRACKS — 每个电台的原版 / 替换状态歌曲列表
// （为了节省篇幅，只保留前几条；完整可对照 data.jsx 第 32 行起）
// ============================================================
const Map<String, List<TrackRef>> kTracks = {
  'HOR': [
    TrackRef(
      id: 'hor-1',
      title: 'Aurora Coast',
      artist: 'Telemetry',
      durationSec: 213.4,
    ),
    TrackRef(
      id: 'hor-2',
      title: 'Long Way Home',
      artist: 'Vela & Plate',
      durationSec: 241.9,
    ),
    TrackRef(
      id: 'hor-3',
      title: 'Skyline Theory',
      artist: 'Nova Pulse',
      durationSec: 197.2,
    ),
    TrackRef(
      id: 'hor-4',
      title: 'Solstice (Edit)',
      artist: 'Halocene',
      durationSec: 228.0,
    ),
    TrackRef(
      id: 'hor-5',
      title: 'Daybreak Highway',
      artist: 'Atlas Run',
      durationSec: 204.7,
      modded: true,
    ),
    TrackRef(
      id: 'hor-6',
      title: 'Glass Towers',
      artist: 'Forecast',
      durationSec: 262.5,
    ),
    TrackRef(
      id: 'hor-7',
      title: 'Drift District',
      artist: 'BRG Theory',
      durationSec: 218.1,
    ),
    TrackRef(
      id: 'hor-8',
      title: 'Mirage Beach',
      artist: 'Coastline Crew',
      durationSec: 235.4,
    ),
  ],
  'BAS': [
    TrackRef(
      id: 'bas-1',
      title: 'Subterrain',
      artist: 'Crawler',
      durationSec: 189.0,
    ),
    TrackRef(
      id: 'bas-2',
      title: 'Phase 0',
      artist: 'Hexside',
      durationSec: 215.3,
    ),
    TrackRef(
      id: 'bas-3',
      title: 'Cardinal',
      artist: 'DRMR',
      durationSec: 203.6,
    ),
    TrackRef(
      id: 'bas-4',
      title: 'Loud System',
      artist: 'Voltura',
      durationSec: 227.0,
    ),
    TrackRef(
      id: 'bas-5',
      title: 'Trench Run',
      artist: 'Subzero Method',
      durationSec: 198.4,
    ),
    TrackRef(
      id: 'bas-6',
      title: 'Mainframe',
      artist: 'Quartz Bloc',
      durationSec: 241.5,
    ),
  ],
  'BLK': [
    TrackRef(
      id: 'blk-1',
      title: 'Block Party Anthem',
      artist: 'Mister M.',
      durationSec: 204.0,
    ),
    TrackRef(
      id: 'blk-2',
      title: 'Cool Off',
      artist: 'Lavender Funk',
      durationSec: 188.7,
    ),
    TrackRef(
      id: 'blk-3',
      title: 'Sundown Roll',
      artist: 'Topaz',
      durationSec: 212.5,
    ),
    TrackRef(
      id: 'blk-4',
      title: 'East 12',
      artist: 'Apex Avenue',
      durationSec: 196.1,
    ),
    TrackRef(
      id: 'blk-5',
      title: 'Loud Talker',
      artist: 'Hugh Mason',
      durationSec: 230.0,
    ),
    TrackRef(
      id: 'blk-6',
      title: 'Hot Coupé',
      artist: 'Brassknock',
      durationSec: 208.6,
    ),
  ],
  'EUR': [
    TrackRef(
      id: 'eur-1',
      title: 'Initial Charge',
      artist: 'Auto Force',
      durationSec: 248.0,
    ),
    TrackRef(
      id: 'eur-2',
      title: 'Mt. Akina Mirror',
      artist: 'Velocita Mio',
      durationSec: 227.6,
    ),
    TrackRef(
      id: 'eur-3',
      title: 'Touge Lights',
      artist: 'Linea Bianca',
      durationSec: 236.0,
    ),
    TrackRef(
      id: 'eur-4',
      title: "Driver's Eyes",
      artist: 'Pole Position',
      durationSec: 218.9,
    ),
  ],
  'ROC': [
    TrackRef(
      id: 'roc-1',
      title: 'Brisa del Sur',
      artist: 'Ferrobronce',
      durationSec: 217.0,
    ),
    TrackRef(
      id: 'roc-2',
      title: 'Vértigo',
      artist: 'Marea Roja',
      durationSec: 201.4,
    ),
    TrackRef(
      id: 'roc-3',
      title: 'Volcán Joven',
      artist: 'Soljero',
      durationSec: 223.7,
    ),
    TrackRef(
      id: 'roc-4',
      title: 'Carreteras',
      artist: 'Castro 7',
      durationSec: 236.5,
    ),
    TrackRef(
      id: 'roc-5',
      title: 'Niebla',
      artist: 'Calle Norte',
      durationSec: 198.0,
    ),
    TrackRef(
      id: 'roc-6',
      title: 'El Tajo',
      artist: 'Banda Cobre',
      durationSec: 244.2,
    ),
  ],
  'XS': [
    TrackRef(
      id: 'xs-1',
      title: 'Iron Procession',
      artist: 'Phasewall',
      durationSec: 271.0,
    ),
    TrackRef(
      id: 'xs-2',
      title: 'Glass Crusher',
      artist: 'Velasco Burn',
      durationSec: 237.5,
    ),
    TrackRef(
      id: 'xs-3',
      title: 'Sirena',
      artist: 'Ortega Sun',
      durationSec: 259.0,
    ),
    TrackRef(
      id: 'xs-4',
      title: 'Hammered Halo',
      artist: 'Vox Tempest',
      durationSec: 248.7,
    ),
    TrackRef(
      id: 'xs-5',
      title: 'Black Ridge',
      artist: 'Saltwire',
      durationSec: 214.2,
    ),
    TrackRef(
      id: 'xs-6',
      title: 'Open Throttle',
      artist: 'Northcoast Echo',
      durationSec: 226.0,
    ),
  ],
  'TIM': [
    TrackRef(
      id: 'tim-1',
      title: 'Easy Cruiser',
      artist: 'The Cellos',
      durationSec: 194.2,
    ),
    TrackRef(
      id: 'tim-2',
      title: 'Sunday Top-Down',
      artist: 'Marcellus Bay',
      durationSec: 212.4,
    ),
    TrackRef(
      id: 'tim-3',
      title: 'Pacific Time',
      artist: 'Henry Foran',
      durationSec: 226.1,
    ),
    TrackRef(
      id: 'tim-4',
      title: 'Heat Mirage',
      artist: 'Polaris Trio',
      durationSec: 217.0,
    ),
    TrackRef(
      id: 'tim-5',
      title: 'Soft Mover',
      artist: 'Carriage 9',
      durationSec: 198.7,
    ),
    TrackRef(
      id: 'tim-6',
      title: 'Easy Tempo',
      artist: 'The Vinces',
      durationSec: 204.0,
    ),
    TrackRef(
      id: 'tim-7',
      title: 'Wide Asphalt',
      artist: 'Lake Avenue',
      durationSec: 230.6,
    ),
    TrackRef(
      id: 'tim-8',
      title: 'Late Reply',
      artist: 'Sands Quartet',
      durationSec: 218.3,
    ),
  ],
  'MIX': [
    TrackRef(
      id: 'mix-1',
      title: 'Studio Continuum',
      artist: 'DJ Set 01',
      durationSec: 482.0,
    ),
    TrackRef(
      id: 'mix-2',
      title: 'Block Continuum',
      artist: 'DJ Set 02',
      durationSec: 498.0,
    ),
    TrackRef(
      id: 'mix-3',
      title: 'Long Player',
      artist: 'DJ Set 03',
      durationSec: 471.5,
    ),
    TrackRef(
      id: 'mix-4',
      title: 'Late Continuum',
      artist: 'DJ Set 04',
      durationSec: 455.2,
    ),
  ],
};

// ============================================================
// CUSTOM_POOL — 用户的自建歌曲池
// ============================================================
const List<PoolTrack> kCustomPool = [
  PoolTrack(
    id: 'cp-1',
    title: 'Midnight Cascade',
    artist: 'Telemetry',
    source: 'midnight-cascade.flac',
    durationSec: 214.3,
    bpm: 128,
    key: 'F#m',
    configured: false,
    confirmed: 2,
    assignedTo: 'HOR',
    slot: 1,
    added: '2 hours ago',
  ),
  PoolTrack(
    id: 'cp-2',
    title: 'Velvet Avenue',
    artist: 'Forecast',
    source: 'velvet-avenue.mp3',
    durationSec: 198.6,
    bpm: 96,
    key: 'Bm',
    configured: true,
    confirmed: 4,
    assignedTo: 'BLK',
    slot: 1,
    added: 'yesterday',
  ),
  PoolTrack(
    id: 'cp-3',
    title: 'Iron in the Carburetor',
    artist: 'Saltwire',
    source: 'iron-carburetor.wav',
    durationSec: 226.8,
    bpm: 142,
    key: 'Em',
    configured: false,
    confirmed: 3,
    assignedTo: null,
    slot: null,
    added: '3 days ago',
  ),
  PoolTrack(
    id: 'cp-4',
    title: 'Slow Convertible',
    artist: 'Sands Quartet',
    source: 'slow-convertible-master.flac',
    durationSec: 218.3,
    bpm: 88,
    key: 'D',
    configured: true,
    confirmed: 4,
    assignedTo: 'BLK',
    slot: 2,
    added: 'last week',
  ),
  PoolTrack(
    id: 'cp-5',
    title: 'Open Throttle (Remix)',
    artist: 'Northcoast Echo',
    source: 'open-throttle-remix.flac',
    durationSec: 202.4,
    bpm: 124,
    key: 'Am',
    configured: true,
    confirmed: 4,
    assignedTo: 'HOR',
    slot: 2,
    added: 'last week',
  ),
  PoolTrack(
    id: 'cp-6',
    title: 'Hot Coupé',
    artist: 'Brassknock',
    source: 'hot-coupe-clean.mp3',
    durationSec: 208.6,
    bpm: 104,
    key: 'G',
    configured: true,
    confirmed: 4,
    assignedTo: 'HOR',
    slot: 3,
    added: 'last week',
  ),
  PoolTrack(
    id: 'cp-7',
    title: 'Carreteras Inversas',
    artist: 'Castro 7',
    source: 'carreteras-inv.wav',
    durationSec: 236.5,
    bpm: 118,
    key: 'F',
    configured: false,
    confirmed: 0,
    assignedTo: null,
    slot: null,
    added: '刚刚',
  ),
  PoolTrack(
    id: 'cp-8',
    title: 'Lake Avenue Drift',
    artist: 'Polaris Trio',
    source: 'lake-avenue-drift.flac',
    durationSec: 230.6,
    bpm: 112,
    key: 'C#m',
    configured: true,
    confirmed: 4,
    assignedTo: 'HOR',
    slot: 4,
    added: 'last week',
  ),
];

// ============================================================
// RECENT_PROJECTS — 启动页最近工程
// ============================================================
const List<RecentProject> kRecentProjects = [
  RecentProject(
    name: 'FH6 Steam · Main Tune',
    path: '~/Documents/FH Radio Studio/fh6-main.rmod.json',
    when: '2 分钟前',
    game: 'FH6',
  ),
  RecentProject(
    name: 'FH6 MS Store · Backup',
    path: '~/Documents/FH Radio Studio/fh6-ms.rmod.json',
    when: '昨天',
    game: 'FH6',
  ),
  RecentProject(
    name: 'FH5 Legacy 移植',
    path: '~/Documents/FH Radio Studio/fh5-port.rmod.json',
    when: '上周',
    game: 'FH5',
  ),
];

// 当前打开的工程（顶栏 pill 显示）。
const String kCurrentProjectName = 'fh6-main.rmod.json';

/// 把秒数格式化为 `m:ss`（custom pool 列表用）。
String formatDurationShort(double seconds) {
  final m = (seconds ~/ 60);
  final s = (seconds % 60).floor();
  return '$m:${s.toString().padLeft(2, '0')}';
}
