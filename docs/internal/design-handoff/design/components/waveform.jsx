// =================================================================
// Waveform visualization
//   - Procedural bar waveform (seeded)
//   - Beat grid + segment lanes
//   - Markers for td, pd, tl_start/end, pl_start/end
//   - Loop range shading
//   - Zoom strip
// =================================================================

// Deterministic pseudo-noise for waveform bars
function seedNoise(seed) {
  let s = seed | 0;
  return () => {
    s = (s * 1664525 + 1013904223) | 0;
    return ((s >>> 0) / 0xFFFFFFFF);
  };
}

// Build a waveform shape: envelope by segment label
function buildWaveform(segments, duration, barCount = 220) {
  const rand = seedNoise(42);
  const bars = [];
  const energy = { intro: 0.30, verse: 0.55, chorus: 0.95, bridge: 0.62, outro: 0.32 };
  for (let i = 0; i < barCount; i++) {
    const t = (i / (barCount - 1)) * duration;
    const seg = segments.find(s => t >= s.start && t < s.end) || segments[segments.length-1];
    const base = energy[seg.label] ?? 0.5;
    const wobble = 0.5 + Math.sin(t * 1.2) * 0.18 + Math.cos(t * 0.45) * 0.1;
    const grain = rand() * 0.35 + 0.65;
    bars.push(Math.max(0.05, Math.min(1.0, base * wobble * grain)));
  }
  return bars;
}

function Waveform({ data, markers, loops, playhead, onSeek, zoom = 1 }) {
  const { duration_sec, segments, beats } = data;
  const bars = useMemo(() => buildWaveform(segments, duration_sec, 220), [segments, duration_sec]);
  const wrapRef = useRef(null);

  const handleClick = (e) => {
    if (!onSeek) return;
    const rect = wrapRef.current.getBoundingClientRect();
    const pct = (e.clientX - rect.left) / rect.width;
    onSeek(Math.max(0, Math.min(duration_sec, pct * duration_sec)));
  };

  const pct = (t) => `${(t / duration_sec) * 100}%`;

  return (
    <div className="wf-canvas" ref={wrapRef} onClick={handleClick}>
      <svg viewBox="0 0 220 130" preserveAspectRatio="none">
        {/* center axis */}
        <line x1="0" y1="65" x2="220" y2="65" stroke="var(--border)" strokeWidth="0.5"/>
        {/* bars */}
        {bars.map((v, i) => {
          const h = v * 60;
          return <rect key={i} x={i + 0.1} y={65 - h} width="0.8" height={h * 2} fill="var(--fg-3)" opacity="0.8"/>;
        })}
        {/* beat ticks - every 8th beat */}
        {beats.filter((_, i) => i % 8 === 0).map((b, i) => (
          <line key={"b"+i} x1={(b / duration_sec) * 220} y1="0" x2={(b / duration_sec) * 220} y2="130" stroke="var(--border-2)" strokeWidth="0.4" opacity="0.5"/>
        ))}
      </svg>

      {/* Overlay: loop shades + markers */}
      <div className="wf-overlay">
        {loops?.tl && (
          <div className="wf-loop-shade tl"
               style={{ left: pct(loops.tl.start), width: `calc(${pct(loops.tl.end)} - ${pct(loops.tl.start)})`}}/>
        )}
        {loops?.pl && (
          <div className="wf-loop-shade pl"
               style={{ left: pct(loops.pl.start), width: `calc(${pct(loops.pl.end)} - ${pct(loops.pl.start)})`}}/>
        )}
        {markers.map(m => (
          <div key={m.key} className={`wf-marker ${m.key}`} style={{ left: pct(m.t) }}>
            <div className="flag">{m.label}</div>
            <div className="stem"/>
          </div>
        ))}
        {playhead != null && (
          <div style={{ position:"absolute", top: 0, bottom: 44, width: 1, background:"var(--fg)", left: pct(playhead), opacity: 0.9, boxShadow:"0 0 4px rgba(255,255,255,0.4)" }}/>
        )}
      </div>

      {/* Segment lane */}
      <div className="wf-segments">
        {segments.map((s, i) => {
          const w = ((s.end - s.start) / duration_sec) * 100;
          return <div key={i} className={`seg ${s.label}`} style={{ width: w + "%" }}>{s.label}</div>;
        })}
      </div>

      {/* time axis */}
      <div className="wf-time-axis">
        {[0, 0.25, 0.5, 0.75, 1].map(p => (
          <span key={p}>{fmtShort(p * duration_sec)}</span>
        ))}
      </div>
    </div>
  );
}

// Zoom strip: tiny overview waveform with selection rectangle
function ZoomStrip({ data, windowStart, windowEnd }) {
  const { duration_sec, segments } = data;
  const bars = useMemo(() => buildWaveform(segments, duration_sec, 120), [segments, duration_sec]);
  const pct = (t) => `${(t / duration_sec) * 100}%`;
  return (
    <div className="wf-zoom">
      <svg viewBox="0 0 120 30" preserveAspectRatio="none">
        <line x1="0" y1="15" x2="120" y2="15" stroke="var(--border)" strokeWidth="0.3"/>
        {bars.map((v, i) => {
          const h = v * 12;
          return <rect key={i} x={i + 0.1} y={15 - h} width="0.8" height={h*2} fill="var(--fg-4)" opacity="0.8"/>;
        })}
      </svg>
      <div className="window" style={{ left: pct(windowStart), width: `calc(${pct(windowEnd)} - ${pct(windowStart)})`}}/>
    </div>
  );
}

Object.assign(window, { Waveform, ZoomStrip });
