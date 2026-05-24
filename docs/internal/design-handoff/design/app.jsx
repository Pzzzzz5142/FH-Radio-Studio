// =================================================================
// App — top-level shell with routing, tweaks, modals
// =================================================================
function App() {
  const [t, setTweak] = window.useTweaks({ accent: "lime", navStyle: "rail", theme: "light" });
  const [route, setRoute] = useState("boot"); // boot | dashboard | pool | playlist | backups | architecture | editor
  const [modal, setModal] = useState(null);
  const [editingTrack, setEditingTrack] = useState(null);

  // Map accent name → swatch for the TweakColor control
  const ACCENT_SWATCH = { lime: "#3fa55c", cyan: "#3a92b8", orange: "#d97333", magenta: "#b04895" };
  const SWATCH_TO_NAME = Object.fromEntries(Object.entries(ACCENT_SWATCH).map(([k,v]) => [v,k]));

  // Apply accent + theme
  useEffect(() => {
    document.documentElement.setAttribute("data-accent", t.accent || "lime");
    document.documentElement.setAttribute("data-theme",  t.theme  || "light");
  }, [t.accent, t.theme]);

  const navigate = (id) => {
    if (id === "settings") return;
    setRoute(id);
  };

  if (route === "boot") {
    return (
      <ProjectPicker onOpen={() => setRoute("dashboard")} />
    );
  }

  const project = "fh6-main.rmod.json";

  const editTrack = (track) => { setEditingTrack(track); setRoute("editor"); };

  return (
    <>
      <div className="shell" data-nav={t.navStyle}>
        <TitleBar project={project} navStyle={t.navStyle} onCommand={() => {}}/>
        <Sidebar active={route === "editor" ? "pool" : route} onNavigate={navigate} navStyle={t.navStyle}/>
        <div className="main" data-screen-label={route}>
          {route === "dashboard"    && <Dashboard onPickRadio={() => setRoute("playlist")} onCustomPool={() => setRoute("pool")} onPlaylist={() => setRoute("playlist")} />}
          {route === "pool"         && <CustomPool onEdit={editTrack} onImport={() => editTrack(CUSTOM_POOL[0])} />}
          {route === "editor"       && <ReplaceEditor track={editingTrack} onBack={() => setRoute("pool")} onWrite={() => setModal("preflight")} />}
          {route === "playlist"     && <PlaylistEditor/>}
          {route === "backups"      && <BackupsPage/>}
          {route === "architecture" && <ArchitecturePage/>}
        </div>
      </div>

      {modal === "preflight" && (
        <PreflightModal
          onClose={() => setModal(null)}
          onCommit={() => { setModal(null); setRoute("backups"); }}
        />
      )}

      <window.TweaksPanel title="Tweaks">
        <window.TweakSection label="主题" />
        <window.TweakRadio
          label="模式"
          value={t.theme}
          options={[
            { value:"light", label:"明亮" },
            { value:"dark",  label:"暗黑" },
          ]}
          onChange={v => setTweak("theme", v)}
        />
        <window.TweakColor
          label="强调色"
          value={ACCENT_SWATCH[t.accent] || ACCENT_SWATCH.lime}
          options={[ACCENT_SWATCH.lime, ACCENT_SWATCH.cyan, ACCENT_SWATCH.orange, ACCENT_SWATCH.magenta]}
          onChange={v => setTweak("accent", SWATCH_TO_NAME[v] || "lime")}
        />
        <window.TweakSection label="布局" />
        <window.TweakRadio
          label="导航样式"
          value={t.navStyle}
          options={[
            { value:"rail",  label:"左侧栏" },
            { value:"tabs",  label:"顶部 Tab" },
          ]}
          onChange={v => setTweak("navStyle", v)}
        />
        <window.TweakSection label="跳转" />
        <window.TweakButton label="返回工程选择" onClick={() => setRoute("boot")}/>
        <window.TweakButton label="打开 Pre-flight 弹窗" onClick={() => setModal("preflight")}/>
      </window.TweaksPanel>
    </>
  );
}

ReactDOM.createRoot(document.getElementById("root")).render(<App/>);
