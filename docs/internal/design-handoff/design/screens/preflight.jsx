// =================================================================
// Pre-flight checklist modal — the last gate before .bank/XML write
// =================================================================
function PreflightModal({ onClose, onCommit }) {
  const E = REPLACEMENT_EDIT;
  const AI = E.ai;
  const td = AI.candidates.td[0];
  const pd = AI.candidates.pd[0];
  const tl = AI.candidates.tl[0];
  const pl = AI.candidates.pl[0];

  const [c1, setC1] = useState(false);
  const [c2, setC2] = useState(false);
  const [c3, setC3] = useState(false);
  const ready = c1 && c2 && c3;

  const rows = [
    { name:"TrackDrop",   field:"TD",  t: td.t,   rate:48000, sec:`${td.t.toFixed(3)} s`, samples: Math.round(td.t * 48000) },
    { name:"PostDrop",    field:"PD",  t: pd.t,   rate:48000, sec:`${pd.t.toFixed(3)} s`, samples: Math.round(pd.t * 48000) },
    { name:"TrackLoop A", field:"TL_start", t: tl.start, rate:44100, sec:`${tl.start.toFixed(3)} s`, samples: Math.round(tl.start * 44100) },
    { name:"TrackLoop B", field:"TL_end",   t: tl.end,   rate:44100, sec:`${tl.end.toFixed(3)} s`,   samples: Math.round(tl.end * 44100) },
    { name:"PostLoop A",  field:"PL_start", t: pl.start, rate:44100, sec:`${pl.start.toFixed(3)} s`, samples: Math.round(pl.start * 44100) },
    { name:"PostLoop B",  field:"PL_end",   t: pl.end,   rate:44100, sec:`${pl.end.toFixed(3)} s`,   samples: Math.round(pl.end * 44100) },
    { name:"总时长",        field:"SampleLength", t: AI.duration_sec, rate:48000, sec:`${AI.duration_sec.toFixed(3)} s`, samples: Math.round(AI.duration_sec * 48000) },
  ];

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal" onClick={e => e.stopPropagation()}>
        <div className="modal-head">
          <div className="eyebrow">不可逆操作 · pre-flight</div>
          <h2>写入游戏文件</h2>
          <p>这是替换的最后一步。下方 6 个时间点将写入 9 个语言版本的 RadioInfo XML，并重打包 R_HOR_Tracks_CU1.assets.bank。原文件会先备份。</p>
        </div>

        <div className="modal-body">
          {/* 6 数值表 */}
          <div className="pf-section">
            <h4>时间点（含 sample 换算）</h4>
            <div className="pf-table">
              <table>
                <thead>
                  <tr>
                    <th>字段</th>
                    <th>名称</th>
                    <th className="right">秒</th>
                    <th className="right">采样率</th>
                    <th className="right">采样数</th>
                  </tr>
                </thead>
                <tbody>
                  {rows.map((r, i) => (
                    <tr key={i}>
                      <td className="b">{r.field}</td>
                      <td>{r.name}</td>
                      <td className="right">{r.sec}</td>
                      <td className="right">{r.rate.toLocaleString()}</td>
                      <td className="right b">{r.samples.toLocaleString()}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>

          {/* 文件 */}
          <div className="pf-section">
            <h4>将被修改的文件</h4>
            <div className="pf-files">
              <div className="file-row write">
                <Icon name="file" size={13}/>
                <span style={{flex:1}}>~/Steam/steamapps/common/ForzaHorizon6/media/audio/fmodbanks/R_HOR_Tracks_CU1.assets.bank</span>
                <span className="tag">replace</span>
                <span>168 MB</span>
              </div>
              <div className="file-row write">
                <Icon name="file" size={13}/>
                <span style={{flex:1}}>~/Steam/steamapps/common/ForzaHorizon6/media/audio/RadioInfo_*.xml (9 个语言)</span>
                <span className="tag">edit</span>
                <span>~ 540 KB</span>
              </div>
              <div className="file-row backup">
                <Icon name="shield" size={13}/>
                <span style={{flex:1}}>~/FH Radio Studio/Backups/2026-05-18T14-32_HOR-slot5/</span>
                <span className="tag">backup</span>
                <span>auto · 增量</span>
              </div>
            </div>
          </div>

          {/* 锁定后果 */}
          <div className="pf-section">
            <h4>替换后，下列 HOR 原曲将被锁定为同一首歌</h4>
            <div style={{display:"flex", flexWrap:"wrap", gap:6}}>
              {TRACKS.HOR.filter(t => !t.modded).map(t => (
                <span key={t.id} className="chip chip-danger" style={{fontSize:11}}>
                  <span className="chip-dot"/>{t.title} — {t.artist}
                </span>
              ))}
            </div>
            <div style={{marginTop:8, fontSize:12, color:"var(--fg-3)"}}>
              想保留以上原曲，请点取消，先去 <b style={{color:"var(--fg-2)"}}>播放列表</b> 把它们挂到其他电台。
            </div>
          </div>

          <div className="divider"/>

          {/* 三个二次确认 */}
          <div>
            <div className="check-row" data-checked={c1} onClick={() => setC1(!c1)}>
              <span className="check-box">{c1 && <Icon name="check" size={11}/>}</span>
              <div className="txt"><b>我已通过试听确认 4 组时间点听感正常。</b>
                <div className="sub">特别是 TL / PL 的拼接处没有可听见的咔嗒声或断点。</div>
              </div>
            </div>
            <div className="check-row" data-checked={c2} onClick={() => setC2(!c2)}>
              <span className="check-box">{c2 && <Icon name="check" size={11}/>}</span>
              <div className="txt"><b>我已在游戏设置中关闭"电台 DJ"。</b>
                <div className="sub">否则 DJ 语音会盖掉切歌时机，听不到 td/pd 的高潮起点。</div>
              </div>
            </div>
            <div className="check-row" data-checked={c3} onClick={() => setC3(!c3)}>
              <span className="check-box">{c3 && <Icon name="check" size={11}/>}</span>
              <div className="txt"><b>我理解这会锁住 HOR 电台的其他原曲。</b>
                <div className="sub">如要保留，请先返回播放列表迁移。</div>
              </div>
            </div>
          </div>
        </div>

        <div className="modal-foot">
          <span className="left">游戏未运行 · FMOD 可写 · 备份目录可用</span>
          <button className="btn" onClick={onClose}>取消</button>
          <button className="btn btn-primary" disabled={!ready} onClick={onCommit}>
            <Icon name="shield" size={12}/> 备份并写入
          </button>
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { PreflightModal });
