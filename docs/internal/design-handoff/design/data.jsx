// =================================================================
// FH Radio Studio sample data — all in-memory, no real game files
// =================================================================

// Radios — each can be in `builtin` or `custom` mode (binary, whole-radio).
// Builtin = unmodified game files, no editing allowed.
// Custom  = the bank has been repacked with songs from the user's pool.
const RADIOS = [
  { code: "HOR",  name: "Horizon Pulse",      hue: "lime",    genre: "电子 / 节拍",   slot: 8 },
  { code: "BAS",  name: "Bass Arena",         hue: "magenta", genre: "Bass / DnB",     slot: 6 },
  { code: "BLK",  name: "Block Party",        hue: "orange",  genre: "Hip-hop",        slot: 6 },
  { code: "EUR",  name: "Eurobeat Express",   hue: "cyan",    genre: "Eurobeat",       slot: 4 },
  { code: "ROC",  name: "Rocas Negras",       hue: "red",     genre: "Latin / Rock",   slot: 6 },
  { code: "XS",   name: "XS",                 hue: "violet",  genre: "Metal / Rock",   slot: 6 },
  { code: "TIM",  name: "Timeless FM",        hue: "yellow",  genre: "Classics",       slot: 8 },
  { code: "MIX",  name: "Mixmaster",          hue: "teal",    genre: "DJ Mix",         slot: 4 },
];

// Current mode per radio. Built-in is the safe default.
const RADIO_MODES = {
  HOR: "custom",
  BAS: "builtin",
  BLK: "custom",
  EUR: "builtin",
  ROC: "builtin",
  XS:  "builtin",
  TIM: "builtin",
  MIX: "builtin",
};

// Original/replacement tracks
const TRACKS = {
  HOR: [
    { id:"hor-1", title:"Aurora Coast",       artist:"Telemetry",        dur:213.4, modded:false },
    { id:"hor-2", title:"Long Way Home",      artist:"Vela & Plate",     dur:241.9, modded:false },
    { id:"hor-3", title:"Skyline Theory",     artist:"Nova Pulse",       dur:197.2, modded:false },
    { id:"hor-4", title:"Solstice (Edit)",    artist:"Halocene",         dur:228.0, modded:false },
    { id:"hor-5", title:"Daybreak Highway",   artist:"Atlas Run",        dur:204.7, modded:true  },
    { id:"hor-6", title:"Glass Towers",       artist:"Forecast",         dur:262.5, modded:false },
    { id:"hor-7", title:"Drift District",     artist:"BRG Theory",       dur:218.1, modded:false },
    { id:"hor-8", title:"Mirage Beach",       artist:"Coastline Crew",   dur:235.4, modded:false },
  ],
  BAS: [
    { id:"bas-1", title:"Subterrain",         artist:"Crawler",          dur:189.0, modded:false },
    { id:"bas-2", title:"Phase 0",            artist:"Hexside",          dur:215.3, modded:false },
    { id:"bas-3", title:"Cardinal",           artist:"DRMR",             dur:203.6, modded:false },
    { id:"bas-4", title:"Loud System",        artist:"Voltura",          dur:227.0, modded:false },
    { id:"bas-5", title:"Trench Run",         artist:"Subzero Method",   dur:198.4, modded:false },
    { id:"bas-6", title:"Mainframe",          artist:"Quartz Bloc",      dur:241.5, modded:false },
  ],
  BLK: [
    { id:"blk-1", title:"Block Party Anthem", artist:"Mister M.",        dur:204.0, modded:false },
    { id:"blk-2", title:"Cool Off",           artist:"Lavender Funk",    dur:188.7, modded:false },
    { id:"blk-3", title:"Sundown Roll",       artist:"Topaz",            dur:212.5, modded:false },
    { id:"blk-4", title:"East 12",            artist:"Apex Avenue",      dur:196.1, modded:false },
    { id:"blk-5", title:"Loud Talker",        artist:"Hugh Mason",       dur:230.0, modded:false },
    { id:"blk-6", title:"Hot Coupé",          artist:"Brassknock",       dur:208.6, modded:false },
  ],
  EUR: [
    { id:"eur-1", title:"Initial Charge",     artist:"Auto Force",       dur:248.0, modded:false },
    { id:"eur-2", title:"Mt. Akina Mirror",   artist:"Velocita Mio",     dur:227.6, modded:false },
    { id:"eur-3", title:"Touge Lights",       artist:"Linea Bianca",     dur:236.0, modded:false },
    { id:"eur-4", title:"Driver's Eyes",      artist:"Pole Position",    dur:218.9, modded:false },
  ],
  ROC: [
    { id:"roc-1", title:"Brisa del Sur",      artist:"Ferrobronce",      dur:217.0, modded:false },
    { id:"roc-2", title:"Vértigo",            artist:"Marea Roja",       dur:201.4, modded:false },
    { id:"roc-3", title:"Volcán Joven",       artist:"Soljero",          dur:223.7, modded:false },
    { id:"roc-4", title:"Carreteras",         artist:"Castro 7",         dur:236.5, modded:false },
    { id:"roc-5", title:"Niebla",             artist:"Calle Norte",      dur:198.0, modded:false },
    { id:"roc-6", title:"El Tajo",            artist:"Banda Cobre",      dur:244.2, modded:false },
  ],
  XS: [
    { id:"xs-1", title:"Iron Procession",     artist:"Phasewall",        dur:271.0, modded:false },
    { id:"xs-2", title:"Glass Crusher",       artist:"Velasco Burn",     dur:237.5, modded:false },
    { id:"xs-3", title:"Sirena",              artist:"Ortega Sun",       dur:259.0, modded:false },
    { id:"xs-4", title:"Hammered Halo",       artist:"Vox Tempest",      dur:248.7, modded:false },
    { id:"xs-5", title:"Black Ridge",         artist:"Saltwire",         dur:214.2, modded:false },
    { id:"xs-6", title:"Open Throttle",       artist:"Northcoast Echo",  dur:226.0, modded:false },
  ],
  TIM: [
    { id:"tim-1", title:"Easy Cruiser",       artist:"The Cellos",       dur:194.2, modded:false },
    { id:"tim-2", title:"Sunday Top-Down",    artist:"Marcellus Bay",    dur:212.4, modded:false },
    { id:"tim-3", title:"Pacific Time",       artist:"Henry Foran",      dur:226.1, modded:false },
    { id:"tim-4", title:"Heat Mirage",        artist:"Polaris Trio",     dur:217.0, modded:false },
    { id:"tim-5", title:"Soft Mover",         artist:"Carriage 9",       dur:198.7, modded:false },
    { id:"tim-6", title:"Easy Tempo",         artist:"The Vinces",       dur:204.0, modded:false },
    { id:"tim-7", title:"Wide Asphalt",       artist:"Lake Avenue",      dur:230.6, modded:false },
    { id:"tim-8", title:"Late Reply",         artist:"Sands Quartet",    dur:218.3, modded:false },
  ],
  MIX: [
    { id:"mix-1", title:"Studio Continuum",   artist:"DJ Set 01",        dur:482.0, modded:false },
    { id:"mix-2", title:"Block Continuum",    artist:"DJ Set 02",        dur:498.0, modded:false },
    { id:"mix-3", title:"Long Player",        artist:"DJ Set 03",        dur:471.5, modded:false },
    { id:"mix-4", title:"Late Continuum",     artist:"DJ Set 04",        dur:455.2, modded:false },
  ],
};

// Active replacement edit (Scenario A)
const REPLACEMENT_EDIT = {
  radio: "HOR",
  slot: 5,
  original: { title:"Daybreak Highway", artist:"Atlas Run", dur:204.7 },
  incoming: { file: "/Users/kira/Music/Sources/midnight-cascade.flac", title:"Midnight Cascade", artist:"User Import", dur:214.309, bpm: 128, key:"F#m" },
  ai: {
    duration_sec: 214.309,
    confidence: 0.78,
    bpm: 128.0,
    candidates: {
      td: [
        { t: 68.72,  score: 0.92, why: "首个 chorus 入口（drop 后 1 拍）" },
        { t: 90.51,  score: 0.61, why: "第二段副歌起始" },
        { t: 152.20, score: 0.44, why: "Bridge 后回归主题" },
      ],
      pd: [
        { t: 148.72, score: 0.88, why: "终段 chorus，能量峰值" },
        { t: 170.50, score: 0.54, why: "Outro 前的最后一次副歌" },
        { t: 90.51,  score: 0.41, why: "回退到第二段副歌" },
      ],
      tl: [
        { start: 23.01,  end: 118.25, score: 0.86, bars: 32, why: "Verse → Chorus，32 小节闭环，downbeat 对齐" },
        { start: 55.01,  end: 118.25, score: 0.74, bars: 24, why: "短版本，更密集" },
        { start: 23.01,  end: 88.13,  score: 0.42, bars: 16, why: "信心不足：循环点频谱不连续" },
      ],
      pl: [
        { start: 97.27,  end: 177.27, score: 0.83, bars: 24, why: "Chorus → Outro 入口，能量回落自然" },
        { start: 120.50, end: 177.27, score: 0.66, bars: 16, why: "更短的尾段循环" },
        { start: 145.00, end: 200.30, score: 0.39, bars: 12, why: "信心不足：会被淡出截断" },
      ],
    },
    beats: Array.from({length: Math.floor(214.309 * 128/60)}, (_,i)=>i*60/128 + 0.184),
    segments: [
      { start:0,      end:23.01,  label:"intro"  },
      { start:23.01,  end:55.01,  label:"verse"  },
      { start:55.01,  end:90.51,  label:"chorus" },
      { start:90.51,  end:118.25, label:"verse"  },
      { start:118.25, end:148.72, label:"bridge" },
      { start:148.72, end:177.27, label:"chorus" },
      { start:177.27, end:214.31, label:"outro"  },
    ],
  },
};

// User-imported songs (the "custom pool").
// Each is independent of any radio assignment — assign by setting `assignedTo`.
// `configured` = all 4 time groups confirmed (TD/PD/TL/PL).
const CUSTOM_POOL = [
  { id:"cp-1", title:"Midnight Cascade",        artist:"Telemetry",       source:"midnight-cascade.flac",      dur:214.3, bpm:128, key:"F#m", configured:false, confirmed:2, assignedTo:"HOR", slot:1, added:"2 hours ago" },
  { id:"cp-2", title:"Velvet Avenue",           artist:"Forecast",        source:"velvet-avenue.mp3",          dur:198.6, bpm:96,  key:"Bm",  configured:true,  confirmed:4, assignedTo:"BLK", slot:1, added:"yesterday"   },
  { id:"cp-3", title:"Iron in the Carburetor",  artist:"Saltwire",        source:"iron-carburetor.wav",        dur:226.8, bpm:142, key:"Em",  configured:false, confirmed:3, assignedTo:null,  slot:null, added:"3 days ago"  },
  { id:"cp-4", title:"Slow Convertible",        artist:"Sands Quartet",   source:"slow-convertible-master.flac", dur:218.3, bpm:88, key:"D",   configured:true,  confirmed:4, assignedTo:"BLK", slot:2, added:"last week"   },
  { id:"cp-5", title:"Open Throttle (Remix)",   artist:"Northcoast Echo", source:"open-throttle-remix.flac",   dur:202.4, bpm:124, key:"Am",  configured:true,  confirmed:4, assignedTo:"HOR", slot:2, added:"last week"   },
  { id:"cp-6", title:"Hot Coupé",               artist:"Brassknock",      source:"hot-coupe-clean.mp3",        dur:208.6, bpm:104, key:"G",   configured:true,  confirmed:4, assignedTo:"HOR", slot:3, added:"last week"   },
  { id:"cp-7", title:"Carreteras Inversas",     artist:"Castro 7",        source:"carreteras-inv.wav",         dur:236.5, bpm:118, key:"F",   configured:false, confirmed:0, assignedTo:null,  slot:null, added:"刚刚"        },
  { id:"cp-8", title:"Lake Avenue Drift",       artist:"Polaris Trio",    source:"lake-avenue-drift.flac",     dur:230.6, bpm:112, key:"C#m", configured:true,  confirmed:4, assignedTo:"HOR", slot:4, added:"last week"   },
];

// Backups — three categories:
//   game     · ORIG game files, made once on first install
//   config   · current mod state (auto, kept up to date)
//   manual   · user-created named snapshots
const BACKUPS = {
  game: {
    when: "首次导入 · 上周 (10/14)",
    size: "1.4 GB",
    files: "9 个 .bank · RadioInfo_*.xml (9 种语言) · game.config",
    integrity: "SHA-256 已校验",
  },
  config: {
    when: "今天 14:32 · 自动",
    size: "168 MB",
    files: "当前配置（2 个 custom 电台 + 池子 8 首） · 含 .rmod.json",
    summary: "HOR, BLK 已切换为 custom",
  },
  manual: [
    { when:"今天 09:14",   name:"对比测试 · 只改 HOR",        files:"R_HOR_Tracks_CU1.assets.bank · RadioInfo_*.xml", size:"168 MB" },
    { when:"昨天 22:01",   name:"加 BLK 之前",                files:"全配置快照",                                     size:"312 MB" },
    { when:"上周 (10/16)",  name:"首次 mod 后",                files:"全配置快照",                                     size:"168 MB" },
  ],
};

// Recent projects (boot screen)
const RECENT_PROJECTS = [
  { name:"FH6 Steam · Main Tune",   path:"~/Documents/FH Radio Studio/fh6-main.rmod.json", when:"2 分钟前",  game:"FH6" },
  { name:"FH6 MS Store · Backup",   path:"~/Documents/FH Radio Studio/fh6-ms.rmod.json",   when:"昨天",       game:"FH6" },
  { name:"FH5 Legacy 移植",          path:"~/Documents/FH Radio Studio/fh5-port.rmod.json",  when:"上周",       game:"FH5" },
];

Object.assign(window, { RADIOS, RADIO_MODES, TRACKS, REPLACEMENT_EDIT, CUSTOM_POOL, BACKUPS, RECENT_PROJECTS });
