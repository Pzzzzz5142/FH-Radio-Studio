// =================================================================
// Sidebar / Tabs nav
// =================================================================

const NAV = [
  { id:"dashboard",    label:"概览",       icon:"dashboard", kbd:"1", group:"" },
  { id:"pool",         label:"自建歌曲",    icon:"music",     kbd:"2", group:"内容" },
  { id:"playlist",     label:"播放列表",    icon:"list",      kbd:"3", group:"" },
  { id:"backups",      label:"备份",       icon:"shield",    kbd:"4", group:"工具" },
  { id:"architecture", label:"系统架构",    icon:"arch",      kbd:"",  group:"" },
];

function Sidebar({ active, onNavigate, navStyle }) {
  if (navStyle === "tabs") {
    return (
      <div className="tabs-bar">
        {NAV.map(item => (
          <div key={item.id}
               className="tab-item"
               data-active={active === item.id}
               onClick={() => onNavigate(item.id)}>
            <Icon name={item.icon}/>
            <span>{item.label}</span>
          </div>
        ))}
        <div style={{flex:1}}/>
        <div className="tab-item">
          <Icon name="command"/>
          <span style={{fontFamily:"var(--mono)", fontSize:11}}>⌘K</span>
        </div>
      </div>
    );
  }

  // rail
  let lastGroup = null;
  return (
    <div className="sidebar">
      {NAV.map(item => {
        const header = item.group && item.group !== lastGroup
          ? <div className="group" key={"g-"+item.group}>{item.group}</div>
          : null;
        lastGroup = item.group || lastGroup;
        return <React.Fragment key={item.id}>
          {header}
          <div className="nav-item"
               data-active={active === item.id}
               onClick={() => onNavigate(item.id)}>
            <span className="nav-icon"><Icon name={item.icon} size={15}/></span>
            <span>{item.label}</span>
            {item.kbd && <span className="nav-kbd">{item.kbd}</span>}
          </div>
        </React.Fragment>;
      })}
      <div style={{flex:1}}/>
      <div className="nav-item" onClick={() => onNavigate("settings")}>
        <span className="nav-icon"><Icon name="settings" size={15}/></span>
        <span>设置</span>
      </div>
      <div style={{padding:"10px", fontFamily:"var(--mono)", fontSize:10.5, color:"var(--fg-4)", lineHeight:1.5}}>
        <div>FH Radio Studio 0.4.2</div>
        <div>FH6 build 2.317.41.0</div>
      </div>
    </div>
  );
}

function TitleBar({ project, navStyle, onCommand }) {
  return (
    <div className="title-bar">
      <div className="traffic"><span className="dot"/><span className="dot"/><span className="dot"/></div>
      <span className="brand"><b>FH Radio Studio</b> · FH6 电台修改工具</span>
      <span className="project-pill">
        <Icon name="folder" size={11}/>
        <span className="file">{project}</span>
        <span style={{color:"var(--fg-4)"}}>·</span>
        <span>已保存</span>
      </span>
      <div className="right">
        <span className="stat"><span className="led"/>FMOD 已连接</span>
        <span className="stat"><span className="led warn"/>游戏未运行</span>
        <span className="stat">备份 23 GB / 50 GB</span>
        <button className="btn btn-sm btn-ghost" onClick={onCommand} title="命令面板">
          <Icon name="command" size={12}/>
          <span style={{fontFamily:"var(--mono)"}}>K</span>
        </button>
      </div>
    </div>
  );
}

Object.assign(window, { Sidebar, TitleBar, NAV });
