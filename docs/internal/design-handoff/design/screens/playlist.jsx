// =================================================================
// Playlist — kanban-style board (original layout).
// Each radio is a column. Builtin radios are locked (no drag-in,
// tracks shown faded with lock). Custom radios accept drops + intra
// reorder. Final column = unassigned pool. Drop onto builtin → trigger
// "switch to custom?" confirmation.
// =================================================================
function PlaylistEditor() {
  const [confirmSwitch, setConfirmSwitch] = useState(null); // { radio, track }
  const [dragId, setDragId] = useState(null);
  const [dragOrigin, setDragOrigin] = useState(null); // "pool" | radio code
  const [overCol, setOverCol] = useState(null);
  const [search, setSearch] = useState("");
  const [mode, setMode] = useState("freeroam");

  // Local mutable pool — mirrors CUSTOM_POOL but reassignable
  const [pool, setPool] = useState(() => CUSTOM_POOL.map(t => ({ ...t })));

  const builtinTracksOf = (code) => TRACKS[code] || [];
  const customTracksOf  = (code) => pool.filter(t => t.assignedTo === code).sort((a,b) => (a.slot ?? 0) - (b.slot ?? 0));
  const unassigned      = pool.filter(t => !t.assignedTo);

  const onDropOnRadio = (r) => {
    if (!dragId) return;
    const track = pool.find(t => t.id === dragId);
    if (!track) { setDragId(null); setOverCol(null); return; }

    if (RADIO_MODES[r.code] === "builtin") {
      setConfirmSwitch({ radio: r, track });
    } else {
      const existing = customTracksOf(r.code);
      setPool(p => p.map(t => t.id === dragId
        ? { ...t, assignedTo: r.code, slot: existing.length + 1 }
        : t));
    }
    setDragId(null); setDragOrigin(null); setOverCol(null);
  };

  const onDropOnPool = () => {
    if (!dragId) return;
    setPool(p => p.map(t => t.id === dragId ? { ...t, assignedTo: null, slot: null } : t));
    setDragId(null); setDragOrigin(null); setOverCol(null);
  };

  const filter = (tracks) => !search ? tracks : tracks.filter(t =>
    t.title.toLowerCase().includes(search.toLowerCase()) ||
    (t.artist || "").toLowerCase().includes(search.toLowerCase())
  );

  return (
    <div className="page page-wide">
      <div className="page-head">
        <div>
          <h1>播放列表</h1>
          <div className="sub">每个电台是二选一：原版 (builtin) 锁定不可编辑 · 自建 (custom) 用池中歌曲整批替换。拖动池子曲目到 custom 电台分配，拖到 builtin 会询问是否切换。</div>
        </div>
        <div className="actions">
          <button className="btn"><Icon name="export" size={12}/> 导出配置</button>
          <button className="btn btn-primary"><Icon name="shield" size={12}/> 写入游戏 (pre-flight)</button>
        </div>
      </div>

      <div className="pl-toolbar">
        <div className="pl-mode">
          <span className="seg" data-active={mode==="freeroam"} onClick={()=>setMode("freeroam")}>FreeRoam · 漫游</span>
          <span className="seg" data-active={mode==="event"}    onClick={()=>setMode("event")}>Event · 比赛</span>
        </div>
        <span style={{color:"var(--fg-3)", fontSize:12}}>两套列表独立保存</span>
        <div style={{flex:1}}/>
        <div className="search" style={{position:"relative"}}>
          <input className="input mono" placeholder="搜索曲目 / 艺术家" style={{paddingLeft:30, width:240}} value={search} onChange={e=>setSearch(e.target.value)}/>
          <span style={{position:"absolute", left:10, top:9, color:"var(--fg-3)"}}><Icon name="search" size={13}/></span>
        </div>
        <span className="chip" style={{borderColor:"var(--accent-3)", color:"var(--accent)", background:"var(--accent-2)"}}>
          <span className="chip-dot" style={{background:"var(--accent)"}}/>custom · 可拖入
        </span>
        <span className="chip chip-muted"><Icon name="lock" size={10}/>builtin · 锁定</span>
      </div>

      <div className="pl-board">
        {RADIOS.map(r => {
          const isCustom = RADIO_MODES[r.code] === "custom";
          const tracks = isCustom ? filter(customTracksOf(r.code)) : filter(builtinTracksOf(r.code));
          const hue = ({lime:130,magenta:340,orange:50,cyan:200,red:25,violet:300,yellow:90,teal:180}[r.hue]) || 130;
          return (
            <div className={`pl-col ${isCustom ? "" : "builtin"}`}
                 key={r.code}
                 data-dragover={overCol === r.code}
                 onDragOver={(e)=>{ if (dragId) { e.preventDefault(); setOverCol(r.code); }}}
                 onDragLeave={()=>{ if (overCol === r.code) setOverCol(null); }}
                 onDrop={()=>onDropOnRadio(r)}>
              <div className="pl-col-head">
                <div className="sw" style={{ color:`oklch(0.55 0.15 ${hue})` }}>{r.code}</div>
                <div style={{minWidth:0, flex:1}}>
                  <div className="nm">{r.name}</div>
                  <div style={{fontSize:10.5, color:"var(--fg-3)", fontFamily:"var(--mono)"}}>{r.genre}</div>
                </div>
                {isCustom
                  ? <span className="chip" style={{padding:"1px 6px", fontSize:10, borderColor:"var(--accent-3)", color:"var(--accent)", background:"var(--accent-2)"}}><span className="chip-dot" style={{background:"var(--accent)"}}/>custom</span>
                  : <span className="chip chip-muted" style={{padding:"1px 6px", fontSize:10}}><Icon name="lock" size={9}/>builtin</span>
                }
              </div>
              <div className="pl-col-meta mono">{tracks.length} / {r.slot}</div>
              <div className="pl-col-body">
                {tracks.length === 0 && (
                  <div style={{padding:"20px 8px", textAlign:"center", color:"var(--fg-4)", fontSize:11.5, fontFamily:"var(--mono)"}}>
                    {isCustom ? "空 · 拖入池中曲目" : "无原版数据"}
                  </div>
                )}
                {tracks.map(t => {
                  const draggable = isCustom; // builtin tracks can't move
                  return (
                    <div key={t.id || t.title}
                         className="pl-track"
                         draggable={draggable}
                         data-modded={isCustom}
                         data-locked={!isCustom}
                         onDragStart={()=>{ setDragId(t.id); setDragOrigin(r.code); }}
                         onDragEnd={()=>{ setDragId(null); setDragOrigin(null); setOverCol(null); }}>
                      {draggable
                        ? <span className="grip"><Icon name="drag" size={12}/></span>
                        : <span className="grip"><Icon name="lock" size={10}/></span>}
                      <div className="meta">
                        <div className="nm">{t.title}</div>
                        <div className="ar">{t.artist}</div>
                      </div>
                      {isCustom && !t.configured && <span className="chip chip-warn" style={{fontSize:9, padding:"0 4px"}}><span className="chip-dot"/>{t.confirmed}/4</span>}
                      <span className="dur">{fmtShort(t.dur)}</span>
                    </div>
                  );
                })}
              </div>
            </div>
          );
        })}

        {/* Pool column */}
        <div className={`pl-col pool-col`}
             data-dragover={overCol === "_pool"}
             onDragOver={(e)=>{ if (dragId) { e.preventDefault(); setOverCol("_pool"); }}}
             onDragLeave={()=>{ if (overCol === "_pool") setOverCol(null); }}
             onDrop={onDropOnPool}>
          <div className="pl-col-head">
            <div className="sw" style={{ color:"var(--fg-2)" }}>
              <Icon name="music" size={12}/>
            </div>
            <div style={{minWidth:0, flex:1}}>
              <div className="nm">池子</div>
              <div style={{fontSize:10.5, color:"var(--fg-3)", fontFamily:"var(--mono)"}}>未分配 · 可拖入</div>
            </div>
          </div>
          <div className="pl-col-meta mono">{unassigned.length} 首</div>
          <div className="pl-col-body">
            {filter(unassigned).length === 0 && (
              <div style={{padding:"20px 8px", textAlign:"center", color:"var(--fg-4)", fontSize:11.5, fontFamily:"var(--mono)"}}>
                所有歌已分配
              </div>
            )}
            {filter(unassigned).map(t => (
              <div key={t.id} className="pl-track"
                   draggable
                   data-modded={true}
                   onDragStart={()=>{ setDragId(t.id); setDragOrigin("pool"); }}
                   onDragEnd={()=>{ setDragId(null); setDragOrigin(null); setOverCol(null); }}>
                <span className="grip"><Icon name="drag" size={12}/></span>
                <div className="meta">
                  <div className="nm">{t.title}</div>
                  <div className="ar">{t.artist}</div>
                </div>
                {!t.configured && <span className="chip chip-warn" style={{fontSize:9, padding:"0 4px"}}><span className="chip-dot"/>{t.confirmed}/4</span>}
                <span className="dur">{fmtShort(t.dur)}</span>
              </div>
            ))}
          </div>
        </div>
      </div>

      <div className="banner info" style={{marginTop:16}}>
        <span className="ic"><Icon name="info" size={14}/></span>
        <div>
          <b>提醒：</b>拖动池中曲目到 builtin 电台会触发模式切换确认（该电台所有原版歌曲将一次性消失）。可在「备份」回滚到 vanilla。
        </div>
      </div>

      {/* Switch-mode confirmation */}
      {confirmSwitch && (
        <div className="modal-backdrop" onClick={() => setConfirmSwitch(null)}>
          <div className="modal" style={{width:540}} onClick={e => e.stopPropagation()}>
            <div className="modal-head">
              <div className="eyebrow">即将切换电台模式</div>
              <h2>把 {confirmSwitch.radio.name} 切换为 custom？</h2>
              <p>该电台目前是 builtin，包含 {(TRACKS[confirmSwitch.radio.code]||[]).length} 首游戏原版歌曲。切换后这些原版歌曲在游戏内将<b style={{color:"var(--danger)"}}>全部消失</b>（不能只换一首）。</p>
            </div>
            <div className="modal-body">
              <div className="pf-section">
                <h4>会消失的原版曲目</h4>
                <div style={{display:"flex", flexWrap:"wrap", gap:6}}>
                  {(TRACKS[confirmSwitch.radio.code] || []).map(t => (
                    <span key={t.id} className="chip chip-danger" style={{fontSize:11}}>
                      <span className="chip-dot"/>{t.title}
                    </span>
                  ))}
                </div>
              </div>
              <div className="pf-section">
                <h4>将分配的曲目</h4>
                <div className="pool-chip" style={{cursor:"default"}}>
                  <div className="pool-chip-info">
                    <div className="pool-chip-title">{confirmSwitch.track.title}</div>
                    <div className="pool-chip-sub">{confirmSwitch.track.artist} · 进入 slot 1</div>
                  </div>
                </div>
              </div>
              <div className="banner info">
                <span className="ic"><Icon name="info" size={14}/></span>
                <div>切换是可逆的——「游戏原版」备份还在，可随时把这个电台切回 builtin。</div>
              </div>
            </div>
            <div className="modal-foot">
              <button className="btn" onClick={() => setConfirmSwitch(null)}>取消</button>
              <button className="btn btn-primary" onClick={() => {
                // pretend: would mutate RADIO_MODES; data const so just close
                setConfirmSwitch(null);
              }}>切换并分配</button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

Object.assign(window, { PlaylistEditor });
