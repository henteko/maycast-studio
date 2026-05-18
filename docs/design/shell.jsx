// shell.jsx — Maycast Studio app chrome: macOS Tahoe-style window frame,
// icon set (SF-Symbol-named, Lucide-styled strokes), and shared primitives.
//
// Shared by every artboard. Exports to window so other Babel scripts pick them up.

const APP_FONT =
  '"Inter", -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif';
const APP_DISPLAY_FONT =
  '"Zen Kaku Gothic New", "Inter", -apple-system, BlinkMacSystemFont, "SF Pro Display", sans-serif';
const APP_MONO_FONT =
  '"JetBrains Mono", ui-monospace, "SF Mono", Menlo, monospace';

// ─────────────────────────────────────────────────────────────
// Icons — minimal stroke library. Names follow the SF Symbol vocabulary
// used in the inventory, drawn in a Lucide-ish 1.6px stroke.
// ─────────────────────────────────────────────────────────────
function Icon({ name, size = 16, color = "currentColor", strokeWidth = 1.6, fill = "none", style }) {
  const s = strokeWidth;
  const stroke = color;
  const common = { width: size, height: size, viewBox: "0 0 24 24", fill, stroke, strokeWidth: s, strokeLinecap: "round", strokeLinejoin: "round", style };
  switch (name) {
    case "waveform":
      return (
        <svg {...common}><path d="M3 12h2M19 12h2M7 8v8M11 5v14M15 9v6M9 10v4M13 7v10M17 11v2"/></svg>
      );
    case "waveform.path.ecg.rectangle":
      return (
        <svg {...common}><rect x="2.5" y="5" width="19" height="14" rx="3"/><path d="M5 12h2l1.5-3 2 6 1.8-4 1.7 2H17"/></svg>
      );
    case "waveform.path":
      return (
        <svg {...common}><path d="M3 12h3l2-6 2 12 2-8 2 6 2-3 2 5 2-4h2"/></svg>
      );
    case "waveform.badge.magnifyingglass":
      return (
        <svg {...common}><path d="M3 12h2l1.5-4 2 8 2-6 1.7 4 1.8-3h1"/><circle cx="17" cy="15" r="3"/><path d="M19.1 17.1L21 19"/></svg>
      );
    case "scissors":
      return (
        <svg {...common}><circle cx="6" cy="7" r="2.5"/><circle cx="6" cy="17" r="2.5"/><path d="M8 8.5L20 16M8 15.5L20 8"/></svg>
      );
    case "sparkles":
    case "wand.and.sparkles":
      return (
        <svg {...common}><path d="M12 4.5l1.4 3.6L17 9.5l-3.6 1.4L12 14.5l-1.4-3.6L7 9.5l3.6-1.4z"/><path d="M19 14l.7 1.8L21.5 16.5l-1.8.7L19 19l-.7-1.8L16.5 16.5l1.8-.7z"/><path d="M5 16l.6 1.4L7 18l-1.4.6L5 20l-.6-1.4L3 18l1.4-.6z"/></svg>
      );
    case "rectangle.stack":
      return (
        <svg {...common}><rect x="3.5" y="7" width="17" height="11" rx="2"/><path d="M6 5h12M7.5 3h9"/></svg>
      );
    case "rectangle.stack.fill":
      return (
        <svg {...{ ...common, fill: color }}><rect x="3.5" y="8" width="17" height="11" rx="2" stroke="none"/><path d="M6 5.5h12M7.5 3.5h9" stroke={color} strokeWidth={s} fill="none"/></svg>
      );
    case "square.stack.3d.down.forward":
      return (
        <svg {...common}><path d="M5 5h10v10H5z"/><path d="M8 8h11v11H8" /></svg>
      );
    case "shippingbox":
      return (
        <svg {...common}><path d="M3.5 7.5L12 11l8.5-3.5M12 11v10.5M3.5 7.5v9L12 21l8.5-4.5v-9L12 3z"/></svg>
      );
    case "plus.rectangle":
      return (
        <svg {...common}><rect x="3.5" y="4.5" width="17" height="15" rx="3"/><path d="M12 9v6M9 12h6"/></svg>
      );
    case "folder":
      return (
        <svg {...common}><path d="M3 8a2 2 0 012-2h4l2 2h8a2 2 0 012 2v7a2 2 0 01-2 2H5a2 2 0 01-2-2z"/></svg>
      );
    case "folder.badge.plus":
      return (
        <svg {...common}><path d="M3 8a2 2 0 012-2h4l2 2h8a2 2 0 012 2v7a2 2 0 01-2 2H5a2 2 0 01-2-2z"/><path d="M12 11v5M9.5 13.5h5" /></svg>
      );
    case "clock":
      return (<svg {...common}><circle cx="12" cy="12" r="8.5"/><path d="M12 7.5V12l3 2"/></svg>);
    case "clock.arrow.circlepath":
      return (<svg {...common}><path d="M3.5 12a8.5 8.5 0 1 0 2.5-6"/><path d="M3.5 4v4h4"/><path d="M12 8v4l2.5 1.5"/></svg>);
    case "play.fill":
      return (<svg {...{ ...common, fill: color }}><path d="M7 5l12 7-12 7z" stroke="none"/></svg>);
    case "play.circle":
      return (<svg {...common}><circle cx="12" cy="12" r="8.5"/><path d="M10 8.5l5 3.5-5 3.5z" fill={color} stroke="none"/></svg>);
    case "pause.fill":
      return (<svg {...{ ...common, fill: color }}><rect x="6.5" y="5" width="4" height="14" rx="1" stroke="none"/><rect x="13.5" y="5" width="4" height="14" rx="1" stroke="none"/></svg>);
    case "stop.fill":
      return (<svg {...{ ...common, fill: color }}><rect x="6" y="6" width="12" height="12" rx="2" stroke="none"/></svg>);
    case "arrow.uturn.backward":
      return (<svg {...common}><path d="M9 14L4 9l5-5"/><path d="M4 9h9a6 6 0 010 12h-3"/></svg>);
    case "arrow.uturn.forward":
      return (<svg {...common}><path d="M15 14l5-5-5-5"/><path d="M20 9h-9a6 6 0 100 12h3"/></svg>);
    case "arrow.up.circle":
      return (<svg {...common}><circle cx="12" cy="12" r="8.5"/><path d="M12 16V8M8.5 11.5L12 8l3.5 3.5"/></svg>);
    case "arrow.down.circle":
      return (<svg {...common}><circle cx="12" cy="12" r="8.5"/><path d="M12 8v8M8.5 12.5L12 16l3.5-3.5"/></svg>);
    case "key.fill":
      return (<svg {...{ ...common, fill: color }}><circle cx="9" cy="12" r="3.5" stroke={color} fill="none"/><path d="M12.5 12H21M18 12v3M15 12v2.5" stroke={color}/></svg>);
    case "key.slash":
      return (<svg {...common}><circle cx="9" cy="12" r="3.5"/><path d="M12.5 12H21M18 12v3"/><path d="M4 20L20 4"/></svg>);
    case "checkmark.seal.fill":
      return (<svg {...{ ...common, fill: color }}><path d="M12 2.5l2.2 1.6 2.7-.2.6 2.6 2.4 1.3-.8 2.6 1 2.5-2.2 1.6-.4 2.7-2.7.4-1.6 2.2L12 18.5l-2.5 1.3-1.6-2.2-2.7-.4-.4-2.7L2.6 13l1-2.5-.8-2.6L5.2 6.5l.6-2.6 2.7.2z" stroke="none"/><path d="M8.5 12l2.5 2.5L16 9.5" stroke="#fff" strokeWidth={2} fill="none"/></svg>);
    case "circle.dashed":
      return (<svg {...common}><circle cx="12" cy="12" r="8.5" strokeDasharray="3 3.5"/></svg>);
    case "exclamationmark.triangle":
    case "exclamationmark.triangle.fill":
      return (<svg {...common}><path d="M12 4l9 16H3z"/><path d="M12 10v4M12 17v.5"/></svg>);
    case "xmark":
      return (<svg {...common}><path d="M6 6l12 12M18 6L6 18"/></svg>);
    case "xmark.circle":
      return (<svg {...common}><circle cx="12" cy="12" r="8.5"/><path d="M9 9l6 6M15 9l-6 6"/></svg>);
    case "plus":
      return (<svg {...common}><path d="M12 5v14M5 12h14"/></svg>);
    case "minus":
      return (<svg {...common}><path d="M5 12h14"/></svg>);
    case "trash":
      return (<svg {...common}><path d="M4 7h16M9 7V5a2 2 0 012-2h2a2 2 0 012 2v2M6 7l1 13a2 2 0 002 2h6a2 2 0 002-2l1-13M10 11v6M14 11v6"/></svg>);
    case "speaker.wave.2":
      return (<svg {...common}><path d="M3 9v6h4l5 4V5L7 9z"/><path d="M16 8.5a4.5 4.5 0 010 7M19 6a8 8 0 010 12"/></svg>);
    case "slider.horizontal.3":
      return (<svg {...common}><path d="M3 7h11M17 7h4M3 12h4M10 12h11M3 17h13M19 17h2"/><circle cx="15" cy="7" r="1.7"/><circle cx="8" cy="12" r="1.7"/><circle cx="17.5" cy="17" r="1.7"/></svg>);
    case "tray.full":
      return (<svg {...common}><path d="M3.5 13.5L5 7a2 2 0 012-2h10a2 2 0 012 2l1.5 6.5"/><path d="M3.5 13.5h5l1 2h5l1-2h5v4a2 2 0 01-2 2H5.5a2 2 0 01-2-2z"/></svg>);
    case "music.note":
    case "music.note.list":
      return (<svg {...common}><path d="M9 17V5l10-2v12"/><circle cx="6.5" cy="17" r="2.5"/><circle cx="16.5" cy="15" r="2.5"/></svg>);
    case "person.2.wave.2":
      return (<svg {...common}><circle cx="9" cy="8" r="3"/><path d="M3.5 19c0-3 2.5-5 5.5-5s5.5 2 5.5 5"/><path d="M17 7c.8.8.8 2.4 0 3.2M19.5 5c1.5 1.5 1.5 4 0 5.5"/></svg>);
    case "text.quote":
      return (<svg {...common}><path d="M5 7h7M5 11h7M5 15h5"/><path d="M17 7v3a3 3 0 01-3 3M21 7v3a3 3 0 01-3 3"/></svg>);
    case "ellipsis":
      return (<svg {...{ ...common, fill: color }}><circle cx="5.5" cy="12" r="1.4" stroke="none"/><circle cx="12" cy="12" r="1.4" stroke="none"/><circle cx="18.5" cy="12" r="1.4" stroke="none"/></svg>);
    case "magnifyingglass":
      return (<svg {...common}><circle cx="11" cy="11" r="6.5"/><path d="M16 16l4 4"/></svg>);
    case "chevron.down":
      return (<svg {...common}><path d="M6 9l6 6 6-6"/></svg>);
    case "chevron.right":
      return (<svg {...common}><path d="M9 6l6 6-6 6"/></svg>);
    case "info.circle":
      return (<svg {...common}><circle cx="12" cy="12" r="8.5"/><path d="M12 11v5M12 8v.5"/></svg>);
    case "spinner":
      return (
        <svg width={size} height={size} viewBox="0 0 24 24" fill="none" style={style}>
          <circle cx="12" cy="12" r="8.5" stroke={color} strokeWidth={s} strokeOpacity="0.18"/>
          <path d="M12 3.5a8.5 8.5 0 018.5 8.5" stroke={color} strokeWidth={s} strokeLinecap="round">
            <animateTransform attributeName="transform" type="rotate" from="0 12 12" to="360 12 12" dur="0.9s" repeatCount="indefinite"/>
          </path>
        </svg>
      );
    default:
      return <svg {...common}><circle cx="12" cy="12" r="6"/></svg>;
  }
}

// ─────────────────────────────────────────────────────────────
// Mac window shell — Tahoe-ish: large radius, soft shadow, translucent
// titlebar, traffic lights, optional menubar row.
// ─────────────────────────────────────────────────────────────
function MacShell({
  width = 1280,
  height = 820,
  title = "Maycast Studio",
  subtitle,
  active = true,
  menubar = false,
  bg = "var(--bg-1)",
  // Pass-through wallpaper tint that bleeds through the titlebar's blur
  wallpaper = "linear-gradient(180deg, #c8e3da 0%, #b8d6dd 60%, #c1d9ea 100%)",
  children,
  style,
}) {
  return (
    <div style={{
      width, height,
      borderRadius: 14,
      overflow: "hidden",
      background: bg,
      boxShadow: active
        ? "0 0 0 0.5px rgba(0,0,0,0.18), 0 1px 1px rgba(0,0,0,0.05), 0 24px 60px -8px rgba(14, 31, 26, 0.32), 0 6px 18px rgba(14,31,26,0.14)"
        : "0 0 0 0.5px rgba(0,0,0,0.16), 0 8px 22px rgba(14,31,26,0.18)",
      display: "flex",
      flexDirection: "column",
      position: "relative",
      fontFamily: APP_FONT,
      color: "var(--fg-1)",
      ...style,
    }}>
      {/* Titlebar */}
      <div style={{
        position: "relative",
        flex: "0 0 auto",
        height: 38,
        display: "flex",
        alignItems: "center",
        padding: "0 14px",
        background: "linear-gradient(180deg, rgba(255,255,255,0.78) 0%, rgba(255,255,255,0.62) 100%)",
        backdropFilter: "blur(28px) saturate(180%)",
        WebkitBackdropFilter: "blur(28px) saturate(180%)",
        borderBottom: "0.5px solid rgba(14,31,26,0.10)",
        zIndex: 5,
      }}>
        {/* Traffic lights */}
        <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
          {[["#ff6058", "rgba(0,0,0,0.18)"], ["#ffbd2e", "rgba(0,0,0,0.18)"], ["#28ca41", "rgba(0,0,0,0.18)"]].map(([bg, br], i) => (
            <span key={i} style={{ width: 12, height: 12, borderRadius: "50%", background: active ? bg : "#d4d4d4", boxShadow: `inset 0 0 0 0.5px ${br}` }}/>
          ))}
        </div>
        {/* Title centered */}
        <div style={{
          position: "absolute", left: 0, right: 0, top: 0, bottom: 0,
          display: "flex", alignItems: "center", justifyContent: "center",
          pointerEvents: "none",
        }}>
          <div style={{ display: "flex", alignItems: "baseline", gap: 8, color: "var(--fg-1)" }}>
            <span style={{ fontSize: 13, fontWeight: 600, letterSpacing: "-0.005em" }}>{title}</span>
            {subtitle && <span style={{ fontSize: 12, color: "var(--fg-3)", fontWeight: 500 }}>— {subtitle}</span>}
          </div>
        </div>
        <div style={{ flex: 1 }}/>
      </div>

      {menubar && <MenuBar/>}

      <div style={{ flex: 1, minHeight: 0, position: "relative", display: "flex", flexDirection: "column" }}>
        {children}
      </div>
    </div>
  );
}

function MenuBar() {
  const items = ["Maycast Studio", "File", "Edit", "Episode", "View", "Window", "Help"];
  return (
    <div style={{
      flex: "0 0 auto",
      height: 28,
      padding: "0 14px",
      display: "flex",
      alignItems: "center",
      gap: 18,
      background: "rgba(255,255,255,0.62)",
      backdropFilter: "blur(18px)",
      WebkitBackdropFilter: "blur(18px)",
      borderBottom: "0.5px solid rgba(14,31,26,0.06)",
      fontSize: 12.5,
      color: "var(--fg-1)",
    }}>
      {items.map((it, i) => (
        <span key={i} style={{
          fontWeight: i === 0 ? 700 : 500,
          fontFamily: i === 0 ? APP_DISPLAY_FONT : APP_FONT,
        }}>{it}</span>
      ))}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// Buttons — borrowed from Maycast marketing kit, scaled for desktop UI.
// ─────────────────────────────────────────────────────────────
function Btn({ kind = "secondary", icon, children, size = "md", style, glow = false, destructive = false, disabled = false }) {
  const heights = { sm: 24, md: 30, lg: 38 };
  const padX = { sm: 10, md: 12, lg: 18 };
  const fz = { sm: 12, md: 13, lg: 14 };
  const h = heights[size];
  const base = {
    height: h,
    padding: `0 ${padX[size]}px`,
    display: "inline-flex",
    alignItems: "center",
    gap: 6,
    fontFamily: APP_FONT,
    fontSize: fz[size],
    fontWeight: 600,
    letterSpacing: "-0.005em",
    borderRadius: size === "sm" ? 6 : 8,
    cursor: "pointer",
    whiteSpace: "nowrap",
    transition: "all 120ms var(--ease-out)",
    opacity: disabled ? 0.4 : 1,
    ...style,
  };
  let palette;
  if (kind === "primary") {
    palette = {
      background: "linear-gradient(180deg, var(--mint-400) 0%, var(--mint-500) 100%)",
      color: "#fff",
      border: "0.5px solid var(--mint-600)",
      boxShadow: glow ? "var(--shadow-mint)" : "inset 0 1px 0 rgba(255,255,255,0.35), 0 1px 1px rgba(15,96,78,0.18)",
    };
  } else if (kind === "secondary") {
    palette = {
      background: "linear-gradient(180deg, #ffffff 0%, #fafcfb 100%)",
      color: "var(--fg-1)",
      border: "0.5px solid var(--border-2)",
      boxShadow: "0 1px 1px rgba(14,31,26,0.06), inset 0 0.5px 0 rgba(255,255,255,0.9)",
    };
  } else if (kind === "ghost") {
    palette = {
      background: "transparent",
      color: "var(--fg-2)",
      border: "0.5px solid transparent",
    };
  } else if (kind === "destructive") {
    palette = {
      background: "linear-gradient(180deg, #ffffff 0%, #fff5f5 100%)",
      color: "var(--danger)",
      border: "0.5px solid #f3c2c2",
      boxShadow: "0 1px 1px rgba(190,40,40,0.06)",
    };
  }
  if (destructive && kind === "secondary") palette.color = "var(--danger)";
  return (
    <button style={{ ...base, ...palette }} disabled={disabled}>
      {icon}
      {children}
    </button>
  );
}

// ─────────────────────────────────────────────────────────────
// Sheet wrapper — modal sheet appearing centered with a dimmed bg.
// Renders an artboard-sized container with the sheet centered + a
// blurred preview of the parent screen behind.
// ─────────────────────────────────────────────────────────────
function SheetFrame({
  width = 720,
  minHeight = 480,
  title,
  subtitle,
  rightHeader,
  footer,
  children,
  backdrop = "linear-gradient(180deg, #d3e8e1 0%, #c3d9e3 100%)",
  style,
}) {
  return (
    <div style={{
      width: "100%", height: "100%",
      background: backdrop,
      position: "relative",
      display: "flex", alignItems: "flex-start", justifyContent: "center",
      paddingTop: 38,
      overflow: "hidden",
    }}>
      {/* Dim wash */}
      <div style={{
        position: "absolute", inset: 0,
        background: "rgba(14,31,26,0.18)",
        backdropFilter: "blur(2px)",
      }}/>
      {/* Sheet */}
      <div style={{
        position: "relative",
        width,
        minHeight,
        background: "var(--bg-1)",
        borderRadius: 14,
        boxShadow: "0 0 0 0.5px rgba(14,31,26,0.12), 0 22px 50px rgba(14,31,26,0.28), 0 8px 16px rgba(14,31,26,0.12)",
        display: "flex", flexDirection: "column",
        overflow: "hidden",
        ...style,
      }}>
        {(title || rightHeader) && (
          <div style={{
            padding: "20px 24px 14px",
            borderBottom: "0.5px solid var(--border-1)",
            display: "flex", alignItems: "flex-start", gap: 16,
          }}>
            <div style={{ flex: 1, minWidth: 0 }}>
              {title && (
                <div style={{
                  fontFamily: APP_DISPLAY_FONT, fontSize: 19, fontWeight: 700,
                  color: "var(--fg-1)", letterSpacing: "-0.005em",
                }}>{title}</div>
              )}
              {subtitle && (
                <div style={{ marginTop: 4, color: "var(--fg-3)", fontSize: 12.5, lineHeight: 1.5 }}>{subtitle}</div>
              )}
            </div>
            {rightHeader}
          </div>
        )}
        <div style={{ flex: 1, padding: "16px 24px", overflow: "auto", minHeight: 0 }}>{children}</div>
        {footer && (
          <div style={{
            padding: "12px 24px",
            borderTop: "0.5px solid var(--border-1)",
            display: "flex", alignItems: "center", gap: 8,
            background: "var(--ink-50)",
          }}>{footer}</div>
        )}
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// Waveform canvas — deterministic pseudo-random peaks per seed.
// `style` controls the visual: "lines" | "blocks" | "gradient".
// ─────────────────────────────────────────────────────────────
function Waveform({ width = 800, height = 64, seed = 1, color = "var(--mint-500)", style = "lines", intensity = 0.85, density = 1, faded = false }) {
  // Deterministic peaks using a sine-based hash
  const N = Math.max(40, Math.floor(width * density / 3));
  const peaks = React.useMemo(() => {
    const out = [];
    for (let i = 0; i < N; i++) {
      const x = i / N;
      const v =
        0.45 +
        0.40 * Math.sin(i * 0.35 + seed * 13) * Math.cos(i * 0.11 + seed * 7) +
        0.18 * Math.sin(i * 0.92 + seed * 21) +
        0.10 * Math.sin(i * 2.3 + seed);
      const env = 0.55 + 0.45 * Math.sin(x * Math.PI); // envelope so center is louder
      out.push(Math.max(0.06, Math.min(1, Math.abs(v) * env * intensity)));
    }
    return out;
  }, [N, seed, intensity]);

  if (style === "blocks") {
    const bw = (width - (N - 1) * 1) / N;
    return (
      <svg width={width} height={height} viewBox={`0 0 ${width} ${height}`} style={{ display: "block", opacity: faded ? 0.45 : 1 }}>
        {peaks.map((p, i) => {
          const h = p * height * 0.92;
          const x = i * (bw + 1);
          return <rect key={i} x={x} y={(height - h) / 2} width={bw} height={h} rx={bw * 0.4} fill={color}/>;
        })}
      </svg>
    );
  }
  if (style === "gradient") {
    const id = `wfg-${seed}-${Math.round(width)}`;
    const bw = (width - (N - 1) * 1) / N;
    return (
      <svg width={width} height={height} viewBox={`0 0 ${width} ${height}`} style={{ display: "block", opacity: faded ? 0.45 : 1 }}>
        <defs>
          <linearGradient id={id} x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor={color} stopOpacity="0.85"/>
            <stop offset="100%" stopColor={color} stopOpacity="0.35"/>
          </linearGradient>
        </defs>
        {peaks.map((p, i) => {
          const h = p * height * 0.92;
          const x = i * (bw + 1);
          return <rect key={i} x={x} y={(height - h) / 2} width={bw} height={h} rx={1.5} fill={`url(#${id})`}/>;
        })}
      </svg>
    );
  }
  // lines (default): a smooth filled wave envelope
  const pts = peaks.map((p, i) => {
    const x = (i / (N - 1)) * width;
    const y = (height / 2) - p * height * 0.45;
    return [x, y];
  });
  const top = pts.map(([x, y]) => `${x},${y}`).join(" L ");
  const bot = pts.slice().reverse().map(([x, y]) => `${x},${height - y}`).join(" L ");
  return (
    <svg width={width} height={height} viewBox={`0 0 ${width} ${height}`} style={{ display: "block", opacity: faded ? 0.45 : 1 }}>
      <path d={`M ${top} L ${bot} Z`} fill={color} fillOpacity="0.85"/>
      <path d={`M ${top}`} stroke={color} strokeWidth={1} fill="none"/>
    </svg>
  );
}

// ─────────────────────────────────────────────────────────────
// Tiny logo for in-app branding
// ─────────────────────────────────────────────────────────────
function LogoMark({ size = 28 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 64 64" aria-label="Maycast">
      <defs>
        <linearGradient id="mg-inapp" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0%" stopColor="#3dd9b0"/>
          <stop offset="100%" stopColor="#1fc298"/>
        </linearGradient>
      </defs>
      <rect x="2" y="2" width="60" height="60" rx="16" fill="url(#mg-inapp)"/>
      <g fill="#ffffff" fillOpacity="0.96">
        <rect x="12" y="22" width="5" height="20" rx="2.5"/>
        <rect x="20" y="16" width="5" height="32" rx="2.5"/>
        <rect x="28" y="26" width="5" height="12" rx="2.5"/>
        <rect x="36" y="16" width="5" height="32" rx="2.5"/>
        <rect x="44" y="22" width="5" height="20" rx="2.5"/>
        <circle cx="51" cy="14" r="3.5"/>
      </g>
    </svg>
  );
}

// ─────────────────────────────────────────────────────────────
// Pill/tag/chip primitives
// ─────────────────────────────────────────────────────────────
function Chip({ children, tone = "neutral", icon, style }) {
  const map = {
    neutral: { bg: "var(--ink-100)", fg: "var(--fg-2)", bd: "transparent" },
    mint:    { bg: "var(--mint-50)", fg: "var(--mint-700)", bd: "var(--mint-200)" },
    sky:     { bg: "var(--sky-50)",  fg: "var(--sky-700)",  bd: "var(--sky-200)" },
    sun:     { bg: "var(--sun-100)", fg: "var(--sun-700)",  bd: "rgba(245,197,24,0.35)" },
    danger:  { bg: "var(--danger-bg)", fg: "var(--danger)", bd: "rgba(239,68,68,0.25)" },
    success: { bg: "var(--success-bg)", fg: "var(--mint-700)", bd: "var(--mint-200)" },
    warning: { bg: "var(--warning-bg)", fg: "#c4760a", bd: "rgba(245,158,11,0.3)" },
  };
  const c = map[tone] || map.neutral;
  return (
    <span style={{
      display: "inline-flex", alignItems: "center", gap: 5,
      padding: "2px 8px", borderRadius: 999,
      fontFamily: APP_FONT, fontSize: 11.5, fontWeight: 600,
      background: c.bg, color: c.fg, border: `0.5px solid ${c.bd}`,
      letterSpacing: "-0.003em",
      ...style,
    }}>
      {icon} {children}
    </span>
  );
}

// Progress bar
function Progress({ value = 0, color = "var(--mint-500)", height = 6, style }) {
  return (
    <div style={{
      width: "100%", height, borderRadius: 999, overflow: "hidden",
      background: "var(--ink-100)", ...style,
    }}>
      <div style={{
        width: `${Math.max(0, Math.min(100, value))}%`,
        height: "100%",
        background: color,
        borderRadius: 999,
        transition: "width 320ms var(--ease-out)",
      }}/>
    </div>
  );
}

// Subtle section background variants
const SOFT_BG = {
  brand: "linear-gradient(180deg, var(--mint-50) 0%, #f6fffb 100%)",
  sky:   "linear-gradient(180deg, var(--sky-50) 0%, #f5fbff 100%)",
  ink:   "var(--ink-50)",
  white: "var(--white)",
};

Object.assign(window, {
  Icon, MacShell, MenuBar, Btn, SheetFrame,
  Waveform, LogoMark, Chip, Progress,
  APP_FONT, APP_DISPLAY_FONT, APP_MONO_FONT, SOFT_BG,
});
