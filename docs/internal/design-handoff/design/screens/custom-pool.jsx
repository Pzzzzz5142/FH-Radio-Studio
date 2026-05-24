// =================================================================
// Custom Tracks Pool — the user's library of imported songs.
// Click a track → enter the editor (secondary screen).
// =================================================================
function CustomPool({ onEdit, onImport }) {
  const [filter, setFilter] = useState("all"); // all | unconfigured | unassigned

  const pool = useMemo(() => {
    if (filter === "unconfigured") return CUSTOM_POOL.filter(t => !t.configured);
    if (filter === "unassigned")   return CUSTOM_POOL.filter(t => !t.assignedTo);
    return CUSTOM_POOL;
  }, [filter]);

  const customRadios = RADIOS.filter(r => RADIO_MODES[r.code] === "custom");
  const counts = {
    configured: CUSTOM_POOL.filter(t => t.configured).length,
    unconfigured: CUSTOM_POOL.filter(t => !t.configured).length,
    unassigned: CUSTOM_POOL.filter(t => !t.assignedTo).length,
  };

  return (
    <div className="page">
      <div className="page-head">
        <div>
          <h1>自建歌曲</h1>
          <div className="sub">你导入的所有曲目。每首歌都需要配置 6 个时间点后才能用于游戏。在「播放列表」里把它们分配到电台。</div>
        </div>
        <div className="actions">
          <button className="btn"><Icon name="folder" size={12}/> 打开目录</button>
          <button className="btn btn-primary" onClick={onImport}><Icon name="import" size={12}/> 导入新曲目</button>
        </div>
      </div>

      <div className="dash-grid">
        <div className="stat-card">
          <div className="label">池子总数</div>
          <div className="value">{CUSTOM_POOL.length}</div>
          <div className="delta">来自 {CUSTOM_POOL.length} 个本地文件</div>
        </div>
        <div className="stat-card">
          <div className="label">已配置 · 可用</div>
          <div className="value">{counts.configured} <span className="unit">/ {CUSTOM_POOL.length}</span></div>
          <div className="delta">6 个时间点全部确认</div>
        </div>
        <div className="stat-card">
          <div className="label">待完成</div>
          <div className="value" style={counts.unconfigured > 0 ? {color:"var(--warn)"} : {}}>{counts.unconfigured}</div>
          <div className="delta">需进入编辑器确认</div>
        </div>
        <div className="stat-card">
          <div className="label">未分配</div>
          <div className="value">{counts.unassigned}</div>
          <div className="delta">不在任何电台中</div>
        </div>
      </div>

      <div className="panel">
        <div className="panel-head">
          <h3>曲目</h3>
          <div className="pl-mode" style={{margin:"0 0 0 8px"}}>
            <span className="seg" data-active={filter==="all"} onClick={()=>setFilter("all")}>全部 · {CUSTOM_POOL.length}</span>
            <span className="seg" data-active={filter==="unconfigured"} onClick={()=>setFilter("unconfigured")}>待完成 · {counts.unconfigured}</span>
            <span className="seg" data-active={filter==="unassigned"} onClick={()=>setFilter("unassigned")}>未分配 · {counts.unassigned}</span>
          </div>
          <div className="right">
            <span className="chip chip-muted"><span className="chip-dot"/>仅自建歌曲可编辑</span>
          </div>
        </div>
        <div className="panel-body no-pad">
          <div className="pool-list">
            <div className="pool-row pool-head">
              <div></div>
              <div>曲目</div>
              <div>来源文件</div>
              <div>分配至</div>
              <div>配置</div>
              <div>添加</div>
              <div></div>
            </div>
            {pool.map(t => {
              const radio = t.assignedTo ? RADIOS.find(r => r.code === t.assignedTo) : null;
              return (
                <div className="pool-row" key={t.id} onClick={() => onEdit(t)}>
                  <div className="pool-art">
                    <Icon name="music" size={14}/>
                  </div>
                  <div>
                    <div className="pool-title">{t.title}</div>
                    <div className="pool-sub">{t.artist} · {fmtShort(t.dur)} · {t.bpm} BPM · {t.key}</div>
                  </div>
                  <div className="pool-src mono">{t.source}</div>
                  <div>
                    {radio
                      ? <span className="chip" style={{borderColor:"var(--accent-3)", color:"var(--accent)", background:"var(--accent-2)"}}>
                          <span className="chip-dot" style={{background:"var(--accent)"}}/>{radio.code} · slot {t.slot}
                        </span>
                      : <span className="chip chip-muted"><span className="chip-dot"/>未分配</span>
                    }
                  </div>
                  <div className="pool-progress">
                    <div className="tp-bars">
                      {[0,1,2,3].map(i => <i key={i} className={i < t.confirmed ? "on" : ""}/>)}
                    </div>
                    <span className="mono" style={{fontSize:10.5, color: t.configured ? "var(--accent)" : "var(--fg-3)"}}>
                      {t.configured ? "已配置" : `${t.confirmed}/4`}
                    </span>
                  </div>
                  <div className="pool-added mono">{t.added}</div>
                  <div className="pool-actions">
                    <button className="btn btn-sm">{t.configured ? "查看" : "继续配置"}</button>
                    <button className="btn btn-sm btn-icon btn-ghost" title="删除" onClick={(e)=>{e.stopPropagation();}}>
                      <Icon name="trash" size={12}/>
                    </button>
                  </div>
                </div>
              );
            })}
            {pool.length === 0 && (
              <div className="empty">
                <h3>这里空空的</h3>
                <p>导入 .mp3 / .flac / .wav 开始构建你的池子</p>
                <button className="btn btn-primary" onClick={onImport}>
                  <Icon name="import" size={12}/> 导入曲目
                </button>
              </div>
            )}
          </div>
        </div>
      </div>

      <div className="banner info" style={{marginTop:14}}>
        <span className="ic"><Icon name="info" size={14}/></span>
        <div>
          <b>怎么"用"这些歌？</b>
          &nbsp;每个电台是二选一：原版 (builtin) 或全部自建 (custom)。
          目前已切换为 custom 的电台有：
          {customRadios.length === 0
            ? <span style={{color:"var(--fg-3)"}}>（无）</span>
            : customRadios.map(r => (
                <span key={r.code} className="chip" style={{marginLeft:6, borderColor:"var(--accent-3)", color:"var(--accent)", background:"var(--accent-2)"}}>
                  <span className="chip-dot" style={{background:"var(--accent)"}}/>{r.code}
                </span>
              ))
          }
          ——这些电台原版 8 首已被替换。前往「播放列表」把池中曲目分配到 slot。
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { CustomPool });
