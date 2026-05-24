// =================================================================
// Project picker (boot screen)
// =================================================================
function ProjectPicker({ onOpen }) {
  return (
    <div className="boot">
      <div className="boot-wrap">
        <div className="boot-logo">
          <div className="mark"/>
          <h1>FH Radio Studio</h1>
          <span className="ver">0.4.2</span>
        </div>
        <div className="boot-tag">为 Forza Horizon 6 (PC) 设计的电台修改工具 · 仅修改本地游戏文件</div>

        <div className="boot-cards">
          <div className="boot-card" onClick={() => onOpen("new")}>
            <div className="ic"><Icon name="plus" size={16}/></div>
            <h3>新建工程</h3>
            <p>从 Steam 或 Microsoft Store 安装路径自动发现游戏，并创建首次完整备份。</p>
          </div>
          <div className="boot-card" onClick={() => onOpen("import")}>
            <div className="ic"><Icon name="import" size={16}/></div>
            <h3>导入 .rmod.json</h3>
            <p>从他人分享的工程文件恢复，或在另一台机器上继续上次的编辑会话。</p>
          </div>
        </div>

        <div className="boot-recent">
          <div className="head">
            <h4>最近工程</h4>
            <span style={{fontFamily:"var(--mono)", fontSize:11, color:"var(--fg-4)"}}>3 个</span>
          </div>
          {RECENT_PROJECTS.map((p, i) => (
            <div className="recent-row" key={i} onClick={() => onOpen(p)}>
              <div className="name">
                <div className="game">{p.game}</div>
                <div>
                  <div style={{fontWeight:500, fontSize:13.5}}>{p.name}</div>
                  <div className="path">{p.path}</div>
                </div>
              </div>
              <div className="meta">8 个电台 · 已替换 4 首</div>
              <div className="when">{p.when}</div>
            </div>
          ))}
        </div>

        <div className="boot-foot">
          <div>FH Radio Studio 不修改账号、存档或在线连接数据。所有写入均通过备份-验证-写入流程。</div>
          <div style={{display:"flex", gap:18}}>
            <a href="#">文档</a>
            <a href="#">GitHub</a>
            <a href="#">报告问题</a>
          </div>
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { ProjectPicker });
