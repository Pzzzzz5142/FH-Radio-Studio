// =================================================================
// Backups — simplified to 3 categories
//   1) 游戏原版备份 · ONE snapshot from first install
//   2) 当前配置备份 · auto, mirrors current mod state
//   3) 手动快照     · named user snapshots
// =================================================================
function BackupsPage() {
  const G = BACKUPS.game;
  const C = BACKUPS.config;

  return (
    <div className="page">
      <div className="page-head">
        <div>
          <h1>备份</h1>
          <div className="sub">三类备份：游戏原版 · 当前配置 · 手动快照。游戏原版只有一份（首次导入时建立），是回到 vanilla 的唯一退路。</div>
        </div>
        <div className="actions">
          <button className="btn"><Icon name="folder" size={12}/> 打开目录</button>
          <button className="btn btn-primary"><Icon name="plus" size={12}/> 新建手动快照</button>
        </div>
      </div>

      {/* ROW 1: ORIG + CONFIG */}
      <div className="bk-row-2">
        <div className="panel bk-card">
          <div className="bk-card-head">
            <span className="bk-tag">游戏原版</span>
            <Icon name="shield" size={14}/>
          </div>
          <div className="bk-card-body">
            <div className="bk-title">vanilla · 首次导入时拍下的全套游戏文件</div>
            <dl className="kv" style={{marginTop:12}}>
              <dt>建立时间</dt><dd>{G.when}</dd>
              <dt>包含文件</dt><dd>{G.files}</dd>
              <dt>大小</dt><dd>{G.size}</dd>
              <dt>完整性</dt><dd><span style={{color:"var(--accent)"}}>✓ {G.integrity}</span></dd>
            </dl>
          </div>
          <div className="bk-card-foot">
            <span style={{flex:1, fontSize:11.5, color:"var(--fg-3)"}}>这是回到 vanilla 的唯一退路。FH Radio Studio 不会自动覆盖它。</span>
            <button className="btn btn-sm">校验</button>
            <button className="btn btn-sm btn-danger">回滚到原版…</button>
          </div>
        </div>

        <div className="panel bk-card">
          <div className="bk-card-head">
            <span className="bk-tag bk-tag-accent">当前配置</span>
            <Icon name="dot" size={14}/>
          </div>
          <div className="bk-card-body">
            <div className="bk-title">live · 你现在的 mod 状态</div>
            <dl className="kv" style={{marginTop:12}}>
              <dt>最后同步</dt><dd>{C.when}</dd>
              <dt>状态</dt><dd>{C.summary}</dd>
              <dt>包含</dt><dd>{C.files}</dd>
              <dt>大小</dt><dd>{C.size}</dd>
            </dl>
          </div>
          <div className="bk-card-foot">
            <span style={{flex:1, fontSize:11.5, color:"var(--fg-3)"}}>每次写入游戏后自动更新。可单独导出 .rmod.json 分享。</span>
            <button className="btn btn-sm"><Icon name="export" size={11}/> 导出</button>
            <button className="btn btn-sm">立即同步</button>
          </div>
        </div>
      </div>

      {/* ROW 2: MANUAL */}
      <div className="panel" style={{marginTop:14}}>
        <div className="panel-head">
          <h3>手动快照 · {BACKUPS.manual.length}</h3>
          <span className="sub">你主动建立的命名快照</span>
          <div className="right">
            <button className="btn btn-sm"><Icon name="plus" size={11}/> 新建</button>
          </div>
        </div>
        <div className="panel-body no-pad">
          <div className="bk-list">
            {BACKUPS.manual.map((m, i) => (
              <div className="bk-row" key={i}>
                <span className="when">{m.when}</span>
                <div className="desc">
                  <div className="t">{m.name}</div>
                  <div className="s">{m.files}</div>
                </div>
                <span className="size">{m.size}</span>
                <div style={{display:"flex", gap:6}}>
                  <button className="btn btn-sm">查看差异</button>
                  <button className="btn btn-sm">恢复为当前</button>
                  <button className="btn btn-sm btn-icon" title="导出"><Icon name="export" size={12}/></button>
                  <button className="btn btn-sm btn-icon btn-ghost btn-danger" title="删除"><Icon name="trash" size={12}/></button>
                </div>
              </div>
            ))}
            {BACKUPS.manual.length === 0 && (
              <div className="empty">
                <h3>暂无手动快照</h3>
                <p>在写入大改动前打个快照，方便随时回到这一刻。</p>
                <button className="btn"><Icon name="plus" size={11}/> 新建快照</button>
              </div>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
Object.assign(window, { BackupsPage });
