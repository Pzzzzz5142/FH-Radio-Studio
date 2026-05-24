// =================================================================
// Time-group card: shared block for td / pd / tl / pl confirmation
// =================================================================

const STATE_LABEL = {
  pending:   { txt: "待确认",   chip: "muted"  },
  suggested: { txt: "AI 已建议", chip: ""       },
  confirmed: { txt: "已确认",    chip: "accent" },
};

function StateChip({ state }) {
  const s = STATE_LABEL[state];
  return <span className={`chip ${s.chip ? "chip-"+s.chip : ""}`}>
    <span className="chip-dot"/>
    {s.txt}
  </span>;
}

// Single point (td or pd)
function PointGroup({ kind, name, sub, candidates, selectedIdx, confirmed, lowConfidence, onSelect, onConfirm, onPreview, onNudge }) {
  const sel = candidates[selectedIdx];
  const state = confirmed ? "confirmed" : sel ? "suggested" : "pending";

  return (
    <div className="panel tg">
      <div className="tg-head">
        <span className={`badge ${kind}`}>{kind.toUpperCase()}</span>
        <div>
          <div className="name">{name}</div>
          <div className="sub">{sub} · 采样率 48000</div>
        </div>
        <div className="right">
          <StateChip state={state}/>
          {!confirmed && sel && (
            <button className="btn btn-sm btn-primary" onClick={() => onConfirm(selectedIdx)}>
              <Icon name="check" size={12}/> 确认
              <span className="btn-kbd">↵</span>
            </button>
          )}
          {confirmed && (
            <button className="btn btn-sm btn-ghost" onClick={() => onConfirm(-1)}>重新选择</button>
          )}
        </div>
      </div>

      {lowConfidence && (
        <div className="tg-warn">
          <Icon name="warn" size={14}/>
          AI 信心不足（top score &lt; 0.5）。请手动指定或听过候选后再确认。
        </div>
      )}

      <div className="tg-body single">
        <div>
          <div style={{fontFamily:"var(--mono)", fontSize:11, color:"var(--fg-3)", marginBottom:8, textTransform:"uppercase", letterSpacing:"0.08em"}}>候选 (top 3)</div>
          <div className="cand-list">
            {candidates.map((c, i) => (
              <div key={i} className="cand"
                   data-selected={selectedIdx === i && !confirmed}
                   data-confirmed={confirmed && selectedIdx === i}
                   onClick={() => onSelect(i)}>
                <span className="rank">{i+1}</span>
                <div>
                  <div className="time">{fmt(c.t)} <span style={{fontSize:10, color:"var(--fg-3)", marginLeft:6}}>= {samples(c.t, 48000)} samples</span></div>
                  <div className="why">{c.why}</div>
                </div>
                <div style={{display:"flex", flexDirection:"column", alignItems:"flex-end", gap:6}}>
                  <div className="score">
                    <ConfidencePip score={c.score}/>
                    <span>{(c.score*100).toFixed(0)}%</span>
                  </div>
                  <div className="actions">
                    <button className="btn btn-sm btn-ghost" onClick={(e)=>{e.stopPropagation(); onPreview(c.t);}} title="从此处试听 8 秒">
                      <Icon name="play" size={11}/> 试听
                    </button>
                  </div>
                </div>
              </div>
            ))}
          </div>

          {sel && (
            <div style={{marginTop:12, display:"grid", gridTemplateColumns:"1fr auto", gap:10, alignItems:"center"}}>
              <div className="fine">
                <span className="lbl">已选</span>
                <span className="val">{fmt(sel.t)}</span>
                <span className="nudge">
                  <button className="btn btn-sm" onClick={() => onNudge(-1, false)} title="后退 1 拍">−拍</button>
                  <button className="btn btn-sm" onClick={() => onNudge(+1, false)} title="前进 1 拍">+拍</button>
                  <button className="btn btn-sm" onClick={() => onNudge(-1, true)} title="后退 10 ms (Shift)">−10ms</button>
                  <button className="btn btn-sm" onClick={() => onNudge(+1, true)} title="前进 10 ms (Shift)">+10ms</button>
                </span>
              </div>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

// Loop pair (tl or pl)
function LoopGroup({ kind, name, sub, candidates, selectedIdx, confirmed, lowConfidence, onSelect, onConfirm, onPreview, onPreviewSeam, bpm }) {
  const sel = candidates[selectedIdx];
  const state = confirmed ? "confirmed" : sel ? "suggested" : "pending";

  return (
    <div className="panel tg">
      <div className="tg-head">
        <span className={`badge ${kind}`}>{kind.toUpperCase()}</span>
        <div>
          <div className="name">{name}</div>
          <div className="sub">{sub} · 采样率 44100 · 必须节拍对齐</div>
        </div>
        <div className="right">
          <StateChip state={state}/>
          {!confirmed && sel && (
            <button className="btn btn-sm btn-primary" onClick={() => onConfirm(selectedIdx)}>
              <Icon name="check" size={12}/> 确认
            </button>
          )}
          {confirmed && (
            <button className="btn btn-sm btn-ghost" onClick={() => onConfirm(-1)}>重新选择</button>
          )}
        </div>
      </div>

      {lowConfidence && (
        <div className="tg-warn">
          <Icon name="warn" size={14}/>
          AI 信心不足。建议先点"试听拼接"听一遍循环点是否无缝，再确认。
        </div>
      )}

      <div className="tg-body">
        <div style={{gridColumn:"1 / -1"}}>
          <div style={{fontFamily:"var(--mono)", fontSize:11, color:"var(--fg-3)", marginBottom:8, textTransform:"uppercase", letterSpacing:"0.08em"}}>候选 (top 3)</div>
          <div className="cand-list">
            {candidates.map((c, i) => (
              <div key={i} className="cand"
                   data-selected={selectedIdx === i && !confirmed}
                   data-confirmed={confirmed && selectedIdx === i}
                   onClick={() => onSelect(i)}>
                <span className="rank">{i+1}</span>
                <div>
                  <div className="time">
                    {fmt(c.start)} <span style={{color:"var(--fg-3)", margin:"0 6px"}}>→</span> {fmt(c.end)}
                    <span style={{fontFamily:"var(--mono)", fontSize:10.5, color:"var(--fg-3)", marginLeft:8}}>
                      Δ {(c.end-c.start).toFixed(2)}s · {c.bars} 小节
                    </span>
                  </div>
                  <div className="why">{c.why}</div>
                </div>
                <div style={{display:"flex", flexDirection:"column", alignItems:"flex-end", gap:6}}>
                  <div className="score">
                    <ConfidencePip score={c.score}/>
                    <span>{(c.score*100).toFixed(0)}%</span>
                  </div>
                  <div className="actions">
                    <button className="btn btn-sm btn-ghost" onClick={(e)=>{e.stopPropagation(); onPreviewSeam(c);}} title="试听 A→B 拼接处 ×3">
                      <Icon name="loop" size={11}/> 试听拼接
                    </button>
                  </div>
                </div>
              </div>
            ))}
          </div>

          {sel && (
            <div style={{marginTop:12, display:"grid", gridTemplateColumns:"1fr 1fr", gap:10}}>
              <div className="fine">
                <span className="lbl">A · start</span>
                <span className="val">{fmt(sel.start)}</span>
                <span className="nudge">
                  <button className="btn btn-sm" title="后退 1 拍">−拍</button>
                  <button className="btn btn-sm" title="前进 1 拍">+拍</button>
                </span>
              </div>
              <div className="fine">
                <span className="lbl">B · end</span>
                <span className="val">{fmt(sel.end)}</span>
                <span className="nudge">
                  <button className="btn btn-sm" title="后退 1 拍">−拍</button>
                  <button className="btn btn-sm" title="前进 1 拍">+拍</button>
                </span>
              </div>
            </div>
          )}

          <div style={{marginTop:10, fontFamily:"var(--mono)", fontSize:11, color:"var(--fg-3)", display:"flex", gap:14, flexWrap:"wrap"}}>
            <span>BPM <span style={{color:"var(--fg)"}}>{bpm.toFixed(1)}</span></span>
            <span>1 拍 = <span style={{color:"var(--fg)"}}>{(60/bpm*1000).toFixed(1)} ms</span></span>
            <span>磁吸 <span style={{color:"var(--accent)"}}>downbeat</span></span>
          </div>
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { PointGroup, LoopGroup, StateChip });
