// =================================================================
// Dashboard — radios overview with mode (builtin / custom)
// =================================================================
function Dashboard({ onPickRadio, onCustomPool, onPlaylist }) {
  const customRadios  = RADIOS.filter(r => RADIO_MODES[r.code] === "custom");
  const builtinRadios = RADIOS.filter(r => RADIO_MODES[r.code] === "builtin");
  const pendingPool   = CUSTOM_POOL.filter(t => !t.configured).length;

  return (
    <div className="page page-wide">
      <div className="page-head">
        <div>
          <h1>电台概览</h1>
          <div className="sub">每个电台是二选一：原版 (builtin) 或全自建 (custom)。原版电台锁定，自建电台用你池子里的歌整批替换。</div>
        </div>
        <div className="actions">
          <button className="btn" onClick={onCustomPool}><Icon name="music" size={12}/> 打开池子</button>
          <button className="btn btn-primary" onClick={onPlaylist}><Icon name="list" size={12}/> 编辑播放列表</button>
        </div>
      </div>

      <div className="dash-grid">
        <div className="stat-card">
          <div className="label">电台 · 总数</div>
          <div className="value">{RADIOS.length}</div>
          <div className="delta">来自 1 个游戏构建</div>
        </div>
        <div className="stat-card">
          <div className="label">Custom 模式</div>
          <div className="value" style={{color:"var(--accent)"}}>{customRadios.length}</div>
          <div className="delta">{customRadios.map(r => r.code).join(" · ") || "无"}</div>
        </div>
        <div className="stat-card">
          <div className="label">Builtin 模式</div>
          <div className="value">{builtinRadios.length}</div>
          <div className="delta">原版游戏内容</div>
        </div>
        <div className="stat-card">
          <div className="label">池子曲目</div>
          <div className="value">{CUSTOM_POOL.length}</div>
          <div className="delta">{pendingPool > 0 ? `${pendingPool} 首待完成` : "全部已配置"}</div>
        </div>
      </div>

      <div className="panel">
        <div className="panel-head">
          <h3>电台</h3>
          <span className="sub">点击查看 · custom 电台可在播放列表里编辑</span>
          <div className="right">
            <span className="chip" style={{borderColor:"var(--accent-3)", color:"var(--accent)", background:"var(--accent-2)"}}>
              <span className="chip-dot" style={{background:"var(--accent)"}}/>custom
            </span>
            <span className="chip chip-muted"><Icon name="lock" size={10}/>builtin</span>
          </div>
        </div>
        <div className="panel-body no-pad">
          <div className="radios-list">
            {RADIOS.map(r => {
              const mode = RADIO_MODES[r.code];
              const isCustom = mode === "custom";
              const assigned = CUSTOM_POOL.filter(t => t.assignedTo === r.code);
              const builtin = TRACKS[r.code] || [];
              return (
                <div className="radio-row" key={r.code} onClick={() => onPickRadio(r)}>
                  <div className="swatch" style={{ color: `oklch(0.55 0.15 ${({lime:130,magenta:340,orange:50,cyan:200,red:25,violet:300,yellow:90,teal:180}[r.hue]) || 130})` }}>{r.code}</div>
                  <div>
                    <div className="name">{r.name}</div>
                    <div className="sub">{r.genre} · {r.slot} 个曲位</div>
                  </div>
                  <div className="meta">
                    {isCustom
                      ? <>
                          <span className="pill" style={{color:"var(--accent)", borderColor:"var(--accent-3)", background:"var(--accent-2)"}}>● custom</span>
                          <span className="pill">已分配 {assigned.length}/{r.slot}</span>
                          {assigned.some(t => !t.configured) &&
                            <span className="pill" style={{color:"var(--warn)", borderColor:"oklch(0.55 0.16 75 / 0.4)"}}>未配置 {assigned.filter(t => !t.configured).length}</span>
                          }
                        </>
                      : <>
                          <span className="pill chip-muted">○ builtin</span>
                          <span className="pill">原版 {builtin.length} 首</span>
                        </>
                    }
                  </div>
                  <span className="arrow"><Icon name="arrow-right" size={14}/></span>
                </div>
              );
            })}
          </div>
        </div>
      </div>

      <div className="banner info" style={{marginTop:24}}>
        <span className="ic"><Icon name="info" size={14}/></span>
        <div>
          <b>工作流：</b>
          先去「自建歌曲」导入并配置你的歌（每首需要 6 个时间点）→ 在「播放列表」把曲目分配到电台 → 第一次拖入会自动把目标电台切换成 custom 模式 → 写入游戏前会有 pre-flight 二次确认。
        </div>
      </div>
    </div>
  );
}
Object.assign(window, { Dashboard });
