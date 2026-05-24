// =================================================================
// Architecture / system diagram page
// =================================================================
function ArchitecturePage() {
  return (
    <div className="page page-wide">
      <div className="page-head">
        <div>
          <h1>系统架构</h1>
          <div className="sub">FH Radio Studio 内部模块、数据流，以及三个核心场景的完整流程。技术栈：Flutter Desktop + 本地 Python sidecar。</div>
        </div>
        <div className="actions">
          <button className="btn"><Icon name="export" size={12}/> 导出 PDF</button>
        </div>
      </div>

      <div className="panel" style={{marginBottom:16}}>
        <div className="panel-head"><h3>模块与数据流</h3><span className="sub">UI ↔ Core ↔ Filesystem</span></div>
        <div className="panel-body no-pad">
          <div className="arch-canvas">
            <div className="arch-grid">
              {/* Column 1: UI */}
              <div className="arch-col">
                <div className="arch-col-head">UI 层 · Flutter</div>
                <div className="arch-node tier-ui">
                  <div className="role">View</div>
                  <h4>Replace Editor</h4>
                  <p>波形 · 4 个时间组 · AI 候选</p>
                  <ul><li>wavesurfer 桥接</li><li>键盘快捷键</li></ul>
                </div>
                <div className="arch-node tier-ui">
                  <div className="role">View</div>
                  <h4>Playlist Editor</h4>
                  <p>多电台并排 · 拖拽 · FreeRoam/Event</p>
                </div>
                <div className="arch-node tier-ui">
                  <div className="role">View</div>
                  <h4>Loop Re-editor</h4>
                  <p>已替换曲目列表 + 复用编辑器</p>
                </div>
                <div className="arch-node tier-ui">
                  <div className="role">View</div>
                  <h4>Pre-flight Dialog</h4>
                  <p>写入前最后一道闸</p>
                </div>
              </div>

              {/* Column 2: Core */}
              <div className="arch-col">
                <div className="arch-col-head">Core · Dart 状态机</div>
                <div className="arch-node">
                  <div className="role">Service</div>
                  <h4>Project / .rmod.json</h4>
                  <p>编辑会话状态 · 用户已确认值 · 候选缓存</p>
                  <ul><li>schema v1</li><li>autosave · 30 s</li></ul>
                </div>
                <div className="arch-node">
                  <div className="role">Service</div>
                  <h4>Edit State Machine</h4>
                  <p>td/pd/tl/pl 四组三态：pending → suggested → confirmed</p>
                  <ul><li>Undo/Redo</li></ul>
                </div>
                <div className="arch-node">
                  <div className="role">Bridge</div>
                  <h4>AI Sidecar (Python · FFI)</h4>
                  <p>本地子进程 · gRPC/MessagePack</p>
                  <ul><li>librosa · madmom</li><li>段落/节拍/loop</li><li>JSON contract</li></ul>
                </div>
                <div className="arch-node">
                  <div className="role">Bridge</div>
                  <h4>FMOD Engine (FFI)</h4>
                  <p>Studio API · bank 解包 / 替换 / 重打包</p>
                  <ul><li>Loudness normalization</li></ul>
                </div>
                <div className="arch-node">
                  <div className="role">Service</div>
                  <h4>XML Writer</h4>
                  <p>RadioInfo_*.xml · 9 语言同步</p>
                  <ul><li>原子写 · 校验后替换</li></ul>
                </div>
              </div>

              {/* Column 3: FS */}
              <div className="arch-col">
                <div className="arch-col-head">游戏文件系统</div>
                <div className="arch-node tier-fs">
                  <div className="role">Read · Write</div>
                  <h4>R*_Tracks_CU1.assets.bank</h4>
                  <p>FMOD bank · 9 个电台</p>
                  <ul><li>~150 MB / 个</li><li>替换 = 锁电台</li></ul>
                </div>
                <div className="arch-node tier-fs">
                  <div className="role">Read · Write</div>
                  <h4>RadioInfo_&lt;LANG&gt;.xml</h4>
                  <p>元数据 · 时间点 · 播放列表</p>
                  <ul><li>td / pd · ×48000</li><li>tl / pl · ×44100</li></ul>
                </div>
                <div className="arch-node tier-fs">
                  <div className="role">Read-only</div>
                  <h4>game.config / version</h4>
                  <p>用于检测 patch 升级 → 提示重新备份</p>
                </div>
                <div className="arch-node">
                  <div className="role">Local store</div>
                  <h4>~/FH Radio Studio/Backups/</h4>
                  <p>增量快照 · 每次写入前自动</p>
                </div>
              </div>
            </div>

            {/* simple flow notes */}
            <div style={{marginTop:24, display:"flex", gap:10, flexWrap:"wrap", fontFamily:"var(--mono)", fontSize:11, color:"var(--fg-3)"}}>
              <span className="chip"><span className="chip-dot" style={{background:"var(--accent)"}}/>UI → Core: user intents</span>
              <span className="chip"><span className="chip-dot" style={{background:"var(--info)"}}/>Core → AI: analyze(file)</span>
              <span className="chip"><span className="chip-dot" style={{background:"oklch(0.78 0.17 30)"}}/>Core → FS: backup() · write() · verify()</span>
              <span className="chip"><span className="chip-dot" style={{background:"var(--warn)"}}/>FS → Core: file watcher (game patched)</span>
            </div>
          </div>
        </div>
      </div>

      {/* User flows */}
      <div className="arch-flows">
        <div className="flow-card">
          <div className="scenario">SCENARIO A</div>
          <h4>替换电台中的某首歌</h4>
          <div className="flow-step"><div className="num">1</div><div className="step-body"><div className="title">选目标 + 拖入文件</div><div className="det">用户选电台和槽位，把 .mp3/.flac/.wav 拖入</div></div></div>
          <div className="flow-step"><div className="num">2</div><div className="step-body"><div className="title">响度归一化</div><div className="det">参考原 .wav，目标 <span className="mono">-14 LUFS</span></div></div></div>
          <div className="flow-step"><div className="num">3</div><div className="step-body"><div className="title">AI 分析</div><div className="det">本地 sidecar 跑 librosa/madmom → 返回 td/pd/tl/pl top-3</div></div></div>
          <div className="flow-step"><div className="num dec">4</div><div className="step-body"><div className="title">用户预听 / 微调 / 确认</div><div className="det">4 组独立确认，每组 pending→suggested→confirmed</div></div></div>
          <div className="flow-step"><div className="num danger">5</div><div className="step-body"><div className="title">Pre-flight checklist</div><div className="det">列出 6 个数值 + 路径 + 备份目标，二次确认</div></div></div>
          <div className="flow-step"><div className="num">6</div><div className="step-body"><div className="title">备份 → 写入 → 校验</div><div className="det">.bank 重打包 + 9 个 XML 同步 + 哈希校验</div></div></div>
        </div>

        <div className="flow-card">
          <div className="scenario">SCENARIO B</div>
          <h4>编辑电台播放列表</h4>
          <div className="flow-step"><div className="num">1</div><div className="step-body"><div className="title">切换 FreeRoam / Event</div><div className="det">两套列表独立存储</div></div></div>
          <div className="flow-step"><div className="num">2</div><div className="step-body"><div className="title">显示 8 个电台 + 各自播放列表</div><div className="det">多列并排，可搜索过滤</div></div></div>
          <div className="flow-step"><div className="num">3</div><div className="step-body"><div className="title">拖拽 · 删除 · 复制</div><div className="det">单击移动 · 双击复制 · 拖出回收站删除</div></div></div>
          <div className="flow-step"><div className="num dec">4</div><div className="step-body"><div className="title">保留原曲提示</div><div className="det">若用户标记将替换某电台，提示先保留原曲</div></div></div>
          <div className="flow-step"><div className="num danger">5</div><div className="step-body"><div className="title">Pre-flight (仅 XML)</div><div className="det">不动 .bank · 仅显示 XML diff</div></div></div>
          <div className="flow-step"><div className="num">6</div><div className="step-body"><div className="title">同步 9 种语言 → 备份 → 写入</div><div className="det">原子替换 · 失败自动回滚</div></div></div>
        </div>

        <div className="flow-card">
          <div className="scenario">SCENARIO C</div>
          <h4>编辑已替换的循环点</h4>
          <div className="flow-step"><div className="num">1</div><div className="step-body"><div className="title">显示已替换列表</div><div className="det">仅用户导入的曲目（原版无法编辑）</div></div></div>
          <div className="flow-step"><div className="num">2</div><div className="step-body"><div className="title">进入编辑器（复用 A 的 4~6 步）</div><div className="det">已确认值作为初始状态展示</div></div></div>
          <div className="flow-step"><div className="num dec">3</div><div className="step-body"><div className="title">重跑 AI 或手动微调</div><div className="det">可选完整重跑，或直接拖动 marker</div></div></div>
          <div className="flow-step"><div className="num">4</div><div className="step-body"><div className="title">试听拼接</div><div className="det">A 前 2s → B → A 再 2s × 3 次</div></div></div>
          <div className="flow-step"><div className="num danger">5</div><div className="step-body"><div className="title">Pre-flight (仅 XML)</div><div className="det">只列出 4 个时间点变更</div></div></div>
          <div className="flow-step"><div className="num">6</div><div className="step-body"><div className="title">秒级写入 (无 .bank 操作)</div><div className="det">写入 9 个 XML，&lt; 200 ms</div></div></div>
        </div>
      </div>

      {/* Tech stack tradeoffs */}
      <div className="panel" style={{marginTop:16}}>
        <div className="panel-head">
          <h3>技术栈推荐</h3>
          <span className="sub">为什么是 Flutter Desktop</span>
        </div>
        <div className="panel-body" style={{display:"grid", gridTemplateColumns:"1fr 1fr 1fr", gap:14}}>
          <div>
            <div style={{fontFamily:"var(--mono)", fontSize:11, color:"var(--accent)", textTransform:"uppercase", letterSpacing:"0.1em", marginBottom:6}}>选 · Flutter Desktop</div>
            <ul style={{margin:0, paddingLeft:18, color:"var(--fg-2)", fontSize:13, lineHeight:1.7}}>
              <li>同一份代码 Windows / macOS / Linux</li>
              <li>原生绘制，波形 60 fps 无压力</li>
              <li>Dart FFI 直连 FMOD C API · 零桥接</li>
              <li>包体积 ~15 MB · 无 Chromium 嵌入</li>
              <li>Python AI 通过 sidecar 子进程 + gRPC</li>
            </ul>
          </div>
          <div>
            <div style={{fontFamily:"var(--mono)", fontSize:11, color:"var(--fg-3)", textTransform:"uppercase", letterSpacing:"0.1em", marginBottom:6}}>不选 · Electron</div>
            <ul style={{margin:0, paddingLeft:18, color:"var(--fg-3)", fontSize:13, lineHeight:1.7}}>
              <li>波形大型 canvas + 大量 marker = 卡顿</li>
              <li>包体积 150 MB+ 起步</li>
              <li>FMOD 调用要走 node-ffi-napi · 额外维护成本</li>
              <li>优点：React/wavesurfer.js 生态成熟</li>
            </ul>
          </div>
          <div>
            <div style={{fontFamily:"var(--mono)", fontSize:11, color:"var(--fg-3)", textTransform:"uppercase", letterSpacing:"0.1em", marginBottom:6}}>不选 · Tauri + React</div>
            <ul style={{margin:0, paddingLeft:18, color:"var(--fg-3)", fontSize:13, lineHeight:1.7}}>
              <li>包小、性能可，但跨平台 webview 行为不一致</li>
              <li>FMOD 需绑定到 Rust → 团队需多一门语言</li>
              <li>音频 stream 走 IPC，与 webaudio 拼接易抖动</li>
            </ul>
          </div>
        </div>
      </div>

      {/* Risks */}
      <div className="panel" style={{marginTop:16}}>
        <div className="panel-head"><h3>风险 & 我没问到的 edge case</h3></div>
        <div className="panel-body" style={{display:"grid", gridTemplateColumns:"1fr 1fr", gap:14, fontSize:13, lineHeight:1.7, color:"var(--fg-2)"}}>
          <div>
            <b style={{color:"var(--warn)"}}>用户最容易卡住的点</b>
            <ul style={{margin:"6px 0 0", paddingLeft:18}}>
              <li>"替换=牺牲整个电台"违反直觉。即使在 dashboard 和 playlist 各放了提示，仍可能事故。建议在 Pre-flight 中显示<b>该电台被锁住的所有原曲列表</b>，强制用户读完。</li>
              <li>AI 信心 0.4–0.6 的灰色地带最危险，用户既懒得听又会被高排名诱导。已用黄色警告强化。</li>
              <li>试听拼接的 2s+2s 太短会听不出问题，太长又拖时间 — 建议加 4s/8s 选项。</li>
            </ul>
          </div>
          <div>
            <b style={{color:"var(--warn)"}}>系统级 edge case</b>
            <ul style={{margin:"6px 0 0", paddingLeft:18}}>
              <li>游戏在写入瞬间被启动 → 文件锁。需要 pre-flight 强制检测游戏进程。</li>
              <li>新 patch 发布后 .bank 偏移变化 → 必须比对 game build 版本 + 重新备份。</li>
              <li>用户导入文件采样率不是 44.1k / 48k 倍数 → 必须重采样，但要明确告知音质损耗。</li>
              <li>用户导入 mono 文件 → FMOD 写入会爆破，需在导入时拒绝或自动升为 stereo。</li>
              <li>不同语言版本 XML 的字符编码不一致（GBK / UTF-8 BOM） → 写入须按原编码保持。</li>
              <li>跨用户分享 .rmod.json 时音频文件不会同步 → 需要明确"工程不含音频"提示，或选项 .rmod.zip 打包音频。</li>
            </ul>
          </div>
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { ArchitecturePage });
