// =================================================================
// Scenario A — Replace track main editor
// =================================================================

// In-progress edit drafts (the user has multiple replacements going)
const DRAFTS = [
  { radio:"HOR", slot:5, title:"Midnight Cascade",     artist:"User Import", confirmed:0, total:4, active:true,  bpm:128 },
  { radio:"BLK", slot:3, title:"Velvet Avenue",        artist:"User Import", confirmed:2, total:4, active:false, bpm:96  },
  { radio:"XS",  slot:2, title:"Iron in the Carburetor", artist:"User Import", confirmed:4, total:4, active:false, bpm:142, broken:true },
];

function TargetPicker({ activeRadio, activeSlot, onPick, onClose }) {
  const [tab, setTab] = useState("drafts"); // drafts | radio
  const [pickedRadio, setPickedRadio] = useState(activeRadio);
  const slots = TRACKS[pickedRadio] || [];

  return (
    <div className="target-picker">
      <div className="tp-head">
        <div className="tp-tabs">
          <span className="seg" data-active={tab==="drafts"} onClick={()=>setTab("drafts")}>正在编辑 · {DRAFTS.length}</span>
          <span className="seg" data-active={tab==="radio"}  onClick={()=>setTab("radio")}>从电台选择</span>
        </div>
        <button className="btn btn-sm btn-ghost" onClick={onClose}><Icon name="x" size={12}/></button>
      </div>

      {tab === "drafts" && (
        <div className="tp-body">
          <div className="tp-section-title">当前 + 草稿</div>
          {DRAFTS.map(d => {
            const r = RADIOS.find(x => x.code === d.radio);
            const isActive = d.radio === activeRadio && d.slot === activeSlot;
            return (
              <div key={d.radio+d.slot}
                   className="tp-row"
                   data-active={isActive}
                   onClick={() => onPick({ radio:d.radio, slot:d.slot, title:d.title })}>
                <div className="tp-swatch">{d.radio}</div>
                <div className="tp-info">
                  <div className="tp-title">
                    {d.title}
                    {isActive && <span className="chip chip-accent" style={{marginLeft:8, fontSize:10}}><span className="chip-dot"/>当前</span>}
                    {d.broken && <span className="chip chip-warn" style={{marginLeft:8, fontSize:10}}><span className="chip-dot"/>loop 异常</span>}
                  </div>
                  <div className="tp-sub">{r.name} · slot {d.slot} · {d.bpm} BPM</div>
                </div>
                <div className="tp-progress">
                  <div className="tp-bars">
                    {[0,1,2,3].map(i => <i key={i} className={i < d.confirmed ? "on" : ""}/>)}
                  </div>
                  <div className="tp-progress-text mono">{d.confirmed}/{d.total} 已确认</div>
                </div>
                <Icon name="arrow-right" size={13}/>
              </div>
            );
          })}
          <div className="tp-foot">
            <button className="btn btn-sm" style={{width:"100%"}}>
              <Icon name="import" size={12}/> 导入新文件 (从场景 A 重新开始)
            </button>
          </div>
        </div>
      )}

      {tab === "radio" && (
        <div className="tp-body">
          <div className="tp-section-title">选择电台</div>
          <div className="tp-radios">
            {RADIOS.map(r => (
              <div key={r.code}
                   className="tp-radio-chip"
                   data-active={r.code === pickedRadio}
                   onClick={() => setPickedRadio(r.code)}>
                {r.code}
              </div>
            ))}
          </div>
          <div className="tp-section-title">选择槽位 · {pickedRadio}</div>
          {slots.map((t, i) => (
            <div key={t.id}
                 className="tp-row"
                 data-active={t.modded}
                 onClick={() => onPick({ radio: pickedRadio, slot: i+1, title: t.title })}>
              <div className="tp-slot-num">slot {i+1}</div>
              <div className="tp-info">
                <div className="tp-title">
                  {t.title}
                  {t.modded && <span className="chip chip-accent" style={{marginLeft:8, fontSize:10}}><span className="chip-dot"/>已替换</span>}
                </div>
                <div className="tp-sub">{t.artist} · {fmtShort(t.dur)}</div>
              </div>
              <Icon name="arrow-right" size={13}/>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

function ReplaceEditor({ track, onBack, onWrite }) {
  const E = REPLACEMENT_EDIT;
  const AI = E.ai;
  const t = track || CUSTOM_POOL[0];
  const [tdIdx, setTdIdx] = useState(0);
  const [pdIdx, setPdIdx] = useState(0);
  const [tlIdx, setTlIdx] = useState(0);
  const [plIdx, setPlIdx] = useState(0);
  const [tdC, setTdC] = useState(t.confirmed >= 1);
  const [pdC, setPdC] = useState(t.confirmed >= 2);
  const [tlC, setTlC] = useState(t.confirmed >= 3);
  const [plC, setPlC] = useState(t.confirmed >= 4);
  const [playing, setPlaying] = useState(false);
  const [playhead, setPlayhead] = useState(0);

  // hotkeys
  useEffect(() => {
    const onKey = (e) => {
      if (e.target.tagName === "INPUT" || e.target.tagName === "TEXTAREA") return;
      if (e.code === "Space") { e.preventDefault(); setPlaying(p => !p); }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  // synthetic playhead
  useEffect(() => {
    if (!playing) return;
    const t = setInterval(() => {
      setPlayhead(p => (p + 0.4) % AI.duration_sec);
    }, 200);
    return () => clearInterval(t);
  }, [playing, AI.duration_sec]);

  const td = AI.candidates.td[tdIdx];
  const pd = AI.candidates.pd[pdIdx];
  const tl = AI.candidates.tl[tlIdx];
  const pl = AI.candidates.pl[plIdx];

  const markers = [];
  if (td) markers.push({ key:"td", label:"TD", t: td.t });
  if (pd) markers.push({ key:"pd", label:"PD", t: pd.t });
  if (tl) {
    markers.push({ key:"tl-a", label:"TL-A", t: tl.start });
    markers.push({ key:"tl-b", label:"TL-B", t: tl.end });
  }
  if (pl) {
    markers.push({ key:"pl-a", label:"PL-A", t: pl.start });
    markers.push({ key:"pl-b", label:"PL-B", t: pl.end });
  }

  const states = {
    td: tdC ? "confirmed" : "suggested",
    pd: pdC ? "confirmed" : "suggested",
    tl: tlC ? "confirmed" : "suggested",
    pl: plC ? "confirmed" : "suggested",
  };
  const allConfirmed = tdC && pdC && tlC && plC;
  const doneCount = [tdC, pdC, tlC, plC].filter(Boolean).length;

  const tlLow = AI.candidates.tl.every(c => c.score < 0.5) || AI.candidates.tl[tlIdx].score < 0.5;
  const plLow = AI.candidates.pl.every(c => c.score < 0.5) || AI.candidates.pl[plIdx].score < 0.5;

  const radio = RADIOS.find(r => r.code === E.radio);

  return (
    <div className="page page-wide">
      <div className="breadcrumb">
        <button className="btn btn-sm btn-ghost" onClick={onBack}>
          <Icon name="arrow-right" size={12} style={{transform:"rotate(180deg)"}}/> 自建歌曲
        </button>
        <span style={{color:"var(--fg-4)"}}>/</span>
        <span style={{color:"var(--fg)", fontWeight:500}}>{t.title}</span>
        <span style={{flex:1}}/>
        <span className="chip chip-muted"><span className="chip-dot"/>{t.assignedTo ? `分配至 ${t.assignedTo} · slot ${t.slot}` : "未分配"}</span>
      </div>

      <div className="page-head">
        <div>
          <h1>{t.title}</h1>
          <div className="sub">{t.artist} · {fmtShort(t.dur)} · {t.bpm} BPM · {t.key} · 配置 6 个时间点，确认后这首歌即可用于游戏。</div>
        </div>
        <div className="actions">
          <button className="btn"><Icon name="export" size={12}/> 导出此曲配置</button>
          <button className="btn btn-primary" disabled={!(tdC && pdC && tlC && plC)} onClick={onWrite}>
            <Icon name="check" size={12}/> 标记为已配置
          </button>
        </div>
      </div>

      {/* Source + key facts */}
      <div className="target" style={{marginBottom:12}}>
        <div className="swatch-lg"><Icon name="music" size={16}/></div>
        <div className="info">
          <div className="title">来源文件</div>
          <div className="arrow-row">
            <span className="to mono">{t.source}</span>
          </div>
        </div>
        <div className="target-chips">
          <span className="chip"><span className="chip-dot"/>响度已归一化 (-14 LUFS)</span>
          <span className="chip"><span className="chip-dot"/>采样率 48 kHz</span>
        </div>
      </div>

      {/* Progress strip — the persistent state of all 4 groups */}
      <div className="progress-strip" style={{marginBottom:14}}>
        {[
          { k:"td", lbl:"TrackDrop · 比赛开始", state: states.td, val: td && fmt(td.t) },
          { k:"pd", lbl:"PostDrop · 冲线后",    state: states.pd, val: pd && fmt(pd.t) },
          { k:"tl", lbl:"TrackLoop · 比赛循环",  state: states.tl, val: tl && `${fmt(tl.start)} → ${fmt(tl.end)}` },
          { k:"pl", lbl:"PostLoop · 冲线循环",   state: states.pl, val: pl && `${fmt(pl.start)} → ${fmt(pl.end)}` },
        ].map(c => (
          <div key={c.k} className="progress-cell" data-state={c.state}>
            <div>
              <div className="step-name">{c.k.toUpperCase()}</div>
              <div className="step-label">{c.lbl}</div>
              <div className="step-state mono">{c.val}</div>
            </div>
            <div className="step-icon">{c.state === "confirmed" && <Icon name="check" size={10}/>}</div>
          </div>
        ))}
      </div>

      <div className="editor">
        <div className="editor-main">
          {/* WAVEFORM */}
          <div className="panel wf-card">
            <div className="wf-toolbar">
              <div className="group">
                <span className="seg" data-active="true">波形</span>
                <span className="seg">频谱</span>
                <span className="seg">+ 节拍</span>
              </div>
              <div className="group">
                <span className="seg" data-active="true">段落</span>
                <span className="seg">和弦</span>
              </div>
              <div className="spacer"/>
              <div className="timecode mono">{fmt(playhead)} <span style={{color:"var(--fg-4)"}}>/ {fmt(AI.duration_sec)}</span></div>
              <button className="btn btn-sm btn-icon"><Icon name="zoom-out" size={12}/></button>
              <button className="btn btn-sm btn-icon"><Icon name="zoom-in" size={12}/></button>
            </div>
            <Waveform
              data={AI}
              markers={markers}
              loops={{ tl: tl ? {start: tl.start, end: tl.end} : null,
                       pl: pl ? {start: pl.start, end: pl.end} : null }}
              playhead={playhead}
              onSeek={setPlayhead}
            />
            <ZoomStrip data={AI} windowStart={0} windowEnd={AI.duration_sec}/>
          </div>

          {/* Transport */}
          <div className="transport">
            <button className="btn btn-icon btn-sm" onClick={() => setPlayhead(0)}><Icon name="skip-back" size={12}/></button>
            <span className="play" onClick={() => setPlaying(p => !p)}>
              <Icon name={playing ? "pause" : "play"} size={16}/>
            </span>
            <button className="btn btn-icon btn-sm"><Icon name="skip-fwd" size={12}/></button>
            <div className="time mono">{fmt(playhead)} <span className="total">/ {fmt(AI.duration_sec)}</span></div>
            <span style={{flex:1}}/>
            <span style={{fontFamily:"var(--mono)", fontSize:11, color:"var(--fg-3)"}}>段：{(AI.segments.find(s => playhead>=s.start && playhead<s.end)||AI.segments[0]).label}</span>
            <span style={{fontFamily:"var(--mono)", fontSize:11, color:"var(--fg-3)"}}>BPM {AI.bpm.toFixed(1)}</span>
            <span className="vol">
              <Icon name="music" size={12}/> -14 LUFS
            </span>
            <span className="kbd">Space</span>
          </div>

          {/* Banner: AI confidence */}
          <div className="banner warn">
            <span className="ic"><Icon name="warn" size={14}/></span>
            <div>
              <b>AI 全局置信度 {(AI.confidence*100).toFixed(0)}%。</b> TL 与 PL 部分候选低于 50%，已用黄色标记。请逐个使用"试听拼接"功能确认循环点无缝，再点击确认。
            </div>
          </div>

          {/* Time groups */}
          <PointGroup
            kind="td"
            name="TrackDrop"
            sub="比赛开始时的播放起点（高潮起点）"
            candidates={AI.candidates.td}
            selectedIdx={tdIdx}
            confirmed={tdC}
            lowConfidence={false}
            onSelect={setTdIdx}
            onConfirm={(i)=>{ if (i<0) setTdC(false); else { setTdIdx(i); setTdC(true); }}}
            onPreview={setPlayhead}
            onNudge={()=>{}}
          />

          <LoopGroup
            kind="tl"
            name="TrackLoop"
            sub="比赛中无缝循环段的两端（A → B → A）"
            candidates={AI.candidates.tl}
            selectedIdx={tlIdx}
            confirmed={tlC}
            lowConfidence={tlLow}
            onSelect={setTlIdx}
            onConfirm={(i)=>{ if (i<0) setTlC(false); else { setTlIdx(i); setTlC(true); }}}
            onPreviewSeam={(c)=>setPlayhead(c.end - 2)}
            bpm={AI.bpm}
          />

          <PointGroup
            kind="pd"
            name="PostDrop"
            sub="冲线动画后的播放起点（次高潮）"
            candidates={AI.candidates.pd}
            selectedIdx={pdIdx}
            confirmed={pdC}
            lowConfidence={false}
            onSelect={setPdIdx}
            onConfirm={(i)=>{ if (i<0) setPdC(false); else { setPdIdx(i); setPdC(true); }}}
            onPreview={setPlayhead}
            onNudge={()=>{}}
          />

          <LoopGroup
            kind="pl"
            name="PostLoop"
            sub="冲线后无缝循环段的两端"
            candidates={AI.candidates.pl}
            selectedIdx={plIdx}
            confirmed={plC}
            lowConfidence={plLow}
            onSelect={setPlIdx}
            onConfirm={(i)=>{ if (i<0) setPlC(false); else { setPlIdx(i); setPlC(true); }}}
            onPreviewSeam={(c)=>setPlayhead(c.end - 2)}
            bpm={AI.bpm}
          />
        </div>

        <div className="editor-side">
          {/* AI status */}
          <div className="panel ai-card">
            <div className="panel-head">
              <h3><span className="led"/> AI 分析</h3>
              <span className="sub">本地模型 · 已完成</span>
              <div className="right"><button className="btn btn-sm btn-ghost">重新跑</button></div>
            </div>
            <div className="panel-body">
              <div className="ai-row"><span className="k">全局置信度</span><span className="v">
                {AI.confidence < 0.5 ? <span className="warn">{(AI.confidence*100).toFixed(0)}%</span> : <span>{(AI.confidence*100).toFixed(0)}%</span>}
              </span></div>
              <div className="ai-row"><span className="k">总时长</span><span className="v">{fmt(AI.duration_sec)}</span></div>
              <div className="ai-row"><span className="k">采样数 (48k)</span><span className="v">{samples(AI.duration_sec, 48000)}</span></div>
              <div className="ai-row"><span className="k">BPM</span><span className="v">{AI.bpm.toFixed(1)}</span></div>
              <div className="ai-row"><span className="k">节拍数</span><span className="v">{AI.beats.length}</span></div>
              <div className="ai-row"><span className="k">段落识别</span><span className="v">{AI.segments.length}</span></div>
              <div className="divider"/>
              <div className="ai-row"><span className="k">TD top score</span><span className="v"><span className="good">92%</span></span></div>
              <div className="ai-row"><span className="k">PD top score</span><span className="v"><span className="good">88%</span></span></div>
              <div className="ai-row"><span className="k">TL top score</span><span className="v"><span className="good">86%</span></span></div>
              <div className="ai-row"><span className="k">PL top score</span><span className="v"><span className="good">83%</span></span></div>
            </div>
          </div>

          {/* Confirmation progress */}
          <div className="panel">
            <div className="panel-head">
              <h3>确认进度</h3>
              <div className="right" style={{fontFamily:"var(--mono)", fontSize:11, color:"var(--fg-3)"}}>{doneCount} / 4</div>
            </div>
            <div className="panel-body" style={{display:"flex", flexDirection:"column", gap:8}}>
              {[
                { k:"TD", ok:tdC, label:"TrackDrop" },
                { k:"PD", ok:pdC, label:"PostDrop" },
                { k:"TL", ok:tlC, label:"TrackLoop" },
                { k:"PL", ok:plC, label:"PostLoop" },
              ].map(s => (
                <div key={s.k} style={{display:"flex", alignItems:"center", gap:10}}>
                  <span className="check-box" data-checked={s.ok} style={s.ok ? {background:"var(--accent)", borderColor:"var(--accent)"} : {}}>
                    {s.ok && <Icon name="check" size={10}/>}
                  </span>
                  <span style={{fontFamily:"var(--mono)", fontSize:11.5, color: s.ok ? "var(--fg)" : "var(--fg-3)"}}>{s.k}</span>
                  <span style={{fontSize:12.5, color: s.ok ? "var(--fg)" : "var(--fg-3)"}}>{s.label}</span>
                  {s.ok && <span style={{marginLeft:"auto", fontFamily:"var(--mono)", fontSize:10.5, color:"var(--accent)"}}>已确认</span>}
                </div>
              ))}
              <div className="divider" style={{margin:"8px 0"}}/>
              <button className="btn btn-primary" disabled={!allConfirmed} onClick={onWrite}>
                <Icon name="shield" size={12}/> 写入游戏 (pre-flight)
              </button>
              <div style={{fontFamily:"var(--mono)", fontSize:10.5, color:"var(--fg-3)", textAlign:"center"}}>所有 4 组确认后启用</div>
            </div>
          </div>

          {/* keyboard shortcuts */}
          <div className="panel">
            <div className="panel-head"><h3>快捷键</h3></div>
            <div className="panel-body" style={{display:"flex", flexDirection:"column", gap:8, fontSize:12}}>
              {[
                ["播放 / 暂停",   ["Space"]],
                ["跳到下一段",    ["1","2","…"]],
                ["确认当前候选",   ["Enter"]],
                ["前进 1 拍",     ["→"]],
                ["毫秒级微调",     ["Shift","→"]],
                ["撤销",         ["⌘","Z"]],
              ].map(([l, ks], i) => (
                <div key={i} style={{display:"flex", justifyContent:"space-between", alignItems:"center"}}>
                  <span style={{color:"var(--fg-2)"}}>{l}</span>
                  <span style={{display:"flex", gap:4}}>{ks.map((k,j)=><span key={j} className="kbd">{k}</span>)}</span>
                </div>
              ))}
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { ReplaceEditor });
