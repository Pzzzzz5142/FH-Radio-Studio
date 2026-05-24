// =================================================================
// Shared UI primitives (icons, helpers)
// =================================================================
const { useState, useEffect, useRef, useMemo, useCallback } = React;

// Minimal stroke icons — inline SVG
function Icon({ name, size = 14 }) {
  const props = { width: size, height: size, viewBox: "0 0 24 24", fill: "none", stroke: "currentColor", strokeWidth: 1.6, strokeLinecap: "round", strokeLinejoin: "round" };
  switch (name) {
    case "dashboard": return <svg {...props}><rect x="3" y="3" width="7" height="9"/><rect x="14" y="3" width="7" height="5"/><rect x="14" y="12" width="7" height="9"/><rect x="3" y="16" width="7" height="5"/></svg>;
    case "swap":      return <svg {...props}><path d="M7 7h13M17 4l3 3-3 3M17 17H4M7 14l-3 3 3 3"/></svg>;
    case "list":      return <svg {...props}><path d="M8 6h13M8 12h13M8 18h13"/><circle cx="3.5" cy="6" r="1"/><circle cx="3.5" cy="12" r="1"/><circle cx="3.5" cy="18" r="1"/></svg>;
    case "loop":      return <svg {...props}><path d="M17 1l4 4-4 4M3 11V9a4 4 0 0 1 4-4h14M7 23l-4-4 4-4M21 13v2a4 4 0 0 1-4 4H3"/></svg>;
    case "history":   return <svg {...props}><path d="M3 12a9 9 0 1 0 3-6.7M3 3v6h6"/><path d="M12 7v5l3 2"/></svg>;
    case "arch":      return <svg {...props}><rect x="3" y="3" width="7" height="7"/><rect x="14" y="3" width="7" height="7"/><rect x="3" y="14" width="7" height="7"/><rect x="14" y="14" width="7" height="7"/><path d="M10 6.5h4M10 17.5h4M6.5 10v4M17.5 10v4"/></svg>;
    case "settings":  return <svg {...props}><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 0 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 0 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 0 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 0 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"/></svg>;
    case "play":      return <svg {...props} fill="currentColor" stroke="none"><path d="M8 5v14l11-7z"/></svg>;
    case "pause":     return <svg {...props} fill="currentColor" stroke="none"><rect x="6" y="5" width="4" height="14"/><rect x="14" y="5" width="4" height="14"/></svg>;
    case "check":     return <svg {...props}><path d="M5 13l4 4L19 7"/></svg>;
    case "x":         return <svg {...props}><path d="M6 6l12 12M18 6L6 18"/></svg>;
    case "arrow-right": return <svg {...props}><path d="M5 12h14M13 5l7 7-7 7"/></svg>;
    case "folder":    return <svg {...props}><path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V7z"/></svg>;
    case "plus":      return <svg {...props}><path d="M12 5v14M5 12h14"/></svg>;
    case "warn":      return <svg {...props}><path d="M12 9v4M12 17h.01M10.3 3.8L1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.8a2 2 0 0 0-3.4 0z"/></svg>;
    case "danger":    return <svg {...props}><circle cx="12" cy="12" r="9"/><path d="M12 8v4M12 16h.01"/></svg>;
    case "info":      return <svg {...props}><circle cx="12" cy="12" r="9"/><path d="M12 8h.01M12 12v4"/></svg>;
    case "search":    return <svg {...props}><circle cx="11" cy="11" r="7"/><path d="M21 21l-4.3-4.3"/></svg>;
    case "drag":      return <svg {...props}><circle cx="9" cy="5" r="1"/><circle cx="15" cy="5" r="1"/><circle cx="9" cy="12" r="1"/><circle cx="15" cy="12" r="1"/><circle cx="9" cy="19" r="1"/><circle cx="15" cy="19" r="1"/></svg>;
    case "zoom-in":   return <svg {...props}><circle cx="11" cy="11" r="7"/><path d="M21 21l-4.3-4.3M11 8v6M8 11h6"/></svg>;
    case "zoom-out":  return <svg {...props}><circle cx="11" cy="11" r="7"/><path d="M21 21l-4.3-4.3M8 11h6"/></svg>;
    case "skip-back": return <svg {...props}><path d="M19 20L9 12l10-8v16zM5 19V5"/></svg>;
    case "skip-fwd":  return <svg {...props}><path d="M5 4l10 8-10 8V4zM19 5v14"/></svg>;
    case "lock":      return <svg {...props}><rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/></svg>;
    case "shield":    return <svg {...props}><path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/></svg>;
    case "trash":     return <svg {...props}><path d="M3 6h18M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2M6 6l1 14a2 2 0 0 0 2 2h6a2 2 0 0 0 2-2l1-14"/></svg>;
    case "copy":      return <svg {...props}><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>;
    case "import":    return <svg {...props}><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4M7 10l5 5 5-5M12 15V3"/></svg>;
    case "export":    return <svg {...props}><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4M17 8l-5-5-5 5M12 3v12"/></svg>;
    case "dot":       return <svg {...props}><circle cx="12" cy="12" r="2"/></svg>;
    case "command":   return <svg {...props}><path d="M18 3a3 3 0 0 0-3 3v12a3 3 0 0 0 3 3 3 3 0 0 0 3-3 3 3 0 0 0-3-3H6a3 3 0 0 0-3 3 3 3 0 0 0 3 3 3 3 0 0 0 3-3V6a3 3 0 0 0-3-3 3 3 0 0 0-3 3 3 3 0 0 0 3 3h12a3 3 0 0 0 3-3 3 3 0 0 0-3-3z"/></svg>;
    case "spark":     return <svg {...props}><path d="M12 2v6M12 16v6M2 12h6M16 12h6M5 5l4 4M15 15l4 4M5 19l4-4M15 9l4-4"/></svg>;
    case "music":     return <svg {...props}><path d="M9 18V5l12-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="18" cy="16" r="3"/></svg>;
    case "file":      return <svg {...props}><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><path d="M14 2v6h6"/></svg>;
    default:          return <svg {...props}><circle cx="12" cy="12" r="6"/></svg>;
  }
}

function fmt(t) {
  if (t == null || isNaN(t)) return "—";
  const sign = t < 0 ? "-" : "";
  t = Math.abs(t);
  const m = Math.floor(t / 60);
  const s = (t % 60);
  return `${sign}${m}:${s.toFixed(2).padStart(5,"0")}`;
}
function fmtShort(t) {
  if (t == null || isNaN(t)) return "—";
  const m = Math.floor(t / 60);
  const s = Math.floor(t % 60);
  return `${m}:${String(s).padStart(2,"0")}`;
}
function samples(t, rate) { return Math.round(t * rate).toLocaleString("en-US"); }

function ConfidencePip({ score }) {
  // 5 bars, based on score 0..1
  const n = Math.round(Math.max(0, Math.min(1, score)) * 5);
  const isLow = score < 0.5;
  return (
    <span className="pip" title={`置信度 ${(score*100).toFixed(0)}%`}>
      {[0,1,2,3,4].map(i => <i key={i} className={i < n ? "on" : ""} style={isLow && i < n ? {background:"var(--warn)"} : {}}/>)}
    </span>
  );
}

Object.assign(window, { Icon, fmt, fmtShort, samples, ConfidencePip });
