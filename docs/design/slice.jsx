// slice.jsx — Slice editor (hero screen) with 3 layout variants.
// A: Track headers on left (default in inventory), transcript on right edge as collapsible column
// B: Track headers on TOP per-track (radical), transcript bottom panel
// C: Track headers on left, transcript OVERLAY (full-width, semi-translucent), filled-block waveforms

// Realistic clip data per track (start in seconds, length in seconds).
const SLICE_CLIPS = {
  host: [
    { s: 0,    l: 12.4, seed: 11 },
    { s: 12.4, l: 18.6, seed: 12 },
    { s: 31.0, l: 22.1, seed: 13, selected: true },
    { s: 53.1, l: 14.8, seed: 14 },
    { s: 67.9, l: 24.5, seed: 15 },
  ],
  guest: [
    { s: 1.2,  l: 10.8, seed: 21 },
    { s: 12.5, l: 15.4, seed: 22 },
    { s: 28.4, l: 26.8, seed: 23, selected: true },
    { s: 55.5, l: 19.2, seed: 24 },
    { s: 74.9, l: 17.4, seed: 25 },
  ],
  remote: [
    { s: 0.4,  l: 17.0, seed: 31 },
    { s: 17.6, l: 9.3,  seed: 32 },
    { s: 27.0, l: 24.6, seed: 33 },
    { s: 51.8, l: 22.4, seed: 34 },
    { s: 74.6, l: 17.2, seed: 35 },
  ],
};

// Transcript lines (timestamp in seconds)
const TRANSCRIPT = {
  host: [
    { t: 1.2,  text: "So this week we’re finally going to talk about the rewrite." },
    { t: 5.8,  text: "It’s been — I don’t know — eight months?" },
    { t: 9.4,  text: "Way too long honestly.", note: true },
    { t: 13.0, text: "I think the team was just tired of fighting the old code." },
    { t: 19.5, text: "Every PR turned into an argument about scope.", current: true },
    { t: 24.2, text: "And nobody wanted to touch the parser." },
    { t: 30.0, text: "That’s where Rust came in, right? Tell them the parser story." },
  ],
  guest: [
    { t: 1.7,  text: "Yeah, okay, so the parser." },
    { t: 4.9,  text: "We had three thousand lines of Python, regex city." },
    { t: 11.0, text: "And it was slow — like, four-second cold start slow." },
    { t: 17.6, text: "Switching to a nom-based parser cut that to 80ms." },
    { t: 24.8, text: "Honestly the speed wasn’t the main reason though." },
    { t: 30.4, text: "It was confidence. The types caught a whole class of bugs." },
  ],
  remote: [
    { t: 8.0,  text: "Sorry, can I jump in?" },
    { t: 11.1, text: "I want to push back a little on the “types caught everything” line." },
    { t: 18.3, text: "We did have a regression in week three." },
    { t: 24.0, text: "Right, the unicode thing. Fair." },
  ],
};

const TRACK_IDS = ["host", "guest", "remote"];
const PX_PER_S = 18; // zoom level
const TRACK_H = 96;
const RULER_H = 28;
const HEADER_W = 130;
const TIMELINE_LEN_S = 95;

function SecondsLabel({ s, mono = true }) {
  return <span style={{ fontFamily: mono ? APP_MONO_FONT : undefined, fontVariantNumeric: "tabular-nums" }}>{s.toFixed(2)}s</span>;
}

function formatTime(seconds) {
  const m = Math.floor(seconds / 60);
  const s = seconds - m * 60;
  return `${m}:${s.toFixed(2).padStart(5, "0")}`;
}

// ─────────────────────────────────────────────────────────────
// Reusable editor pieces
// ─────────────────────────────────────────────────────────────

function EditorToolbar({ playing = false, playhead = 38.42, variant = "A", transcriptOpen = true }) {
  return (
    <div style={{
      flex: "0 0 auto",
      height: 52,
      padding: "0 16px",
      display: "flex", alignItems: "center", gap: 10,
      borderBottom: "0.5px solid var(--border-1)",
      background: "linear-gradient(180deg, #fafdfc 0%, #f3f8f6 100%)",
    }}>
      {/* Transport */}
      <div style={{ display: "flex", alignItems: "center", gap: 4, padding: 2, background: "#fff", border: "0.5px solid var(--border-1)", borderRadius: 9, boxShadow: "var(--shadow-xs)" }}>
        <div style={{
          width: 30, height: 30, borderRadius: 7,
          background: playing ? "var(--mint-50)" : "linear-gradient(180deg, var(--mint-400), var(--mint-500))",
          color: playing ? "var(--mint-700)" : "#fff",
          display: "flex", alignItems: "center", justifyContent: "center",
          boxShadow: playing ? "none" : "var(--shadow-xs)",
        }}>
          <Icon name={playing ? "pause.fill" : "play.fill"} size={13} color={playing ? "var(--mint-700)" : "#fff"}/>
        </div>
        <div style={{ width: 30, height: 30, borderRadius: 7, display: "flex", alignItems: "center", justifyContent: "center", color: "var(--fg-2)" }}>
          <Icon name="stop.fill" size={12}/>
        </div>
        <div style={{ width: 56, height: 30, padding: "0 8px", display: "flex", alignItems: "center", justifyContent: "space-between", borderLeft: "0.5px solid var(--border-1)", color: "var(--fg-2)" }}>
          <span style={{ fontSize: 12, fontFamily: APP_MONO_FONT, fontWeight: 600 }}>1.0×</span>
          <Icon name="chevron.down" size={11} color="var(--fg-3)"/>
        </div>
      </div>

      {/* Edit Undo/Redo */}
      <div style={{ display: "flex", alignItems: "center", gap: 4, padding: 2, background: "#fff", border: "0.5px solid var(--border-1)", borderRadius: 9 }}>
        <ToolbarIconBtn icon="arrow.uturn.backward"/>
        <ToolbarIconBtn icon="arrow.uturn.forward" disabled/>
      </div>

      {/* Edit actions */}
      <Btn kind="secondary" icon={<Icon name="scissors" size={13} color="var(--sky-600)"/>}>
        Split (2) @ playhead
      </Btn>
      <Btn kind="destructive" icon={<Icon name="trash" size={13}/>}>Delete (2)</Btn>
      <ToolbarIconBtn icon="text.quote" active={transcriptOpen}/>

      <div style={{ width: 1, height: 22, background: "var(--border-1)", margin: "0 2px" }}/>

      {/* Zoom */}
      <div style={{ display: "flex", alignItems: "center", gap: 8, padding: "0 4px" }}>
        <ToolbarIconBtn icon="minus" small/>
        <div style={{ width: 100, height: 4, background: "var(--ink-100)", borderRadius: 999, position: "relative" }}>
          <div style={{ position: "absolute", left: 0, top: 0, width: "30%", height: "100%", background: "var(--mint-400)", borderRadius: 999 }}/>
          <div style={{ position: "absolute", left: "calc(30% - 7px)", top: -5, width: 14, height: 14, borderRadius: "50%", background: "#fff", border: "0.5px solid var(--border-2)", boxShadow: "var(--shadow-xs)" }}/>
        </div>
        <ToolbarIconBtn icon="plus" small/>
        <span style={{ fontFamily: APP_MONO_FONT, fontSize: 11, color: "var(--fg-3)", minWidth: 50 }}>{PX_PER_S} px/s</span>
      </div>

      <div style={{ flex: 1 }}/>

      {/* Playhead */}
      <div style={{
        padding: "6px 10px", background: "var(--ink-50)",
        borderRadius: 8, border: "0.5px solid var(--border-1)",
        fontFamily: APP_MONO_FONT, fontSize: 12, color: "var(--fg-1)", fontWeight: 600,
      }}>
        {formatTime(playhead)}
      </div>
      <div style={{ width: 1, height: 22, background: "var(--border-1)", margin: "0 2px" }}/>
      <Btn kind="ghost" disabled>Reset</Btn>
      <Btn kind="primary" icon={<Icon name="checkmark.seal.fill" size={13} color="#fff"/>}>
        Apply
        <KeyHint mod label="↩"/>
      </Btn>
    </div>
  );
}

function ToolbarIconBtn({ icon, active, disabled, small }) {
  const sz = small ? 22 : 26;
  return (
    <div style={{
      width: sz, height: sz, borderRadius: 6,
      background: active ? "var(--mint-100)" : "transparent",
      color: active ? "var(--mint-700)" : "var(--fg-2)",
      opacity: disabled ? 0.35 : 1,
      display: "flex", alignItems: "center", justifyContent: "center",
    }}>
      <Icon name={icon} size={small ? 12 : 13}/>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// Timeline pieces
// ─────────────────────────────────────────────────────────────

function TimeRuler({ width, lenS = TIMELINE_LEN_S, pxPerS = PX_PER_S }) {
  const ticks = [];
  for (let s = 0; s <= lenS; s += 5) {
    const big = s % 10 === 0;
    ticks.push(
      <g key={s}>
        <line x1={s * pxPerS} y1={big ? 14 : 18} x2={s * pxPerS} y2={26} stroke={big ? "var(--ink-400)" : "var(--ink-300)"} strokeWidth={0.6}/>
        {big && <text x={s * pxPerS + 4} y={14} fontFamily={APP_MONO_FONT} fontSize="10" fill="var(--fg-3)">{s}s</text>}
      </g>
    );
  }
  return (
    <svg width={width} height={RULER_H} style={{ display: "block" }}>
      <rect width={width} height={RULER_H} fill="var(--ink-50)"/>
      <line x1={0} y1={RULER_H - 0.5} x2={width} y2={RULER_H - 0.5} stroke="var(--border-1)" strokeWidth={0.5}/>
      {ticks}
    </svg>
  );
}

function ClipBlock({ clip, pxPerS = PX_PER_S, waveStyle = "lines", trackHighlight = false, trackId }) {
  const w = clip.l * pxPerS;
  return (
    <div style={{
      position: "absolute",
      left: clip.s * pxPerS, top: 8,
      width: w, height: TRACK_H - 16,
      background: clip.selected ? "var(--mint-100)" : "var(--mint-50)",
      border: clip.selected ? "1.5px solid var(--mint-500)" : "0.5px solid var(--mint-300)",
      borderRadius: 8,
      boxShadow: clip.selected ? "0 4px 16px rgba(31,194,152,0.25)" : "var(--shadow-xs)",
      overflow: "hidden",
      display: "flex", flexDirection: "column",
    }}>
      <div style={{
        flex: 1,
        display: "flex", alignItems: "center", padding: "4px 6px",
      }}>
        <Waveform
          width={Math.max(20, w - 12)} height={TRACK_H - 36}
          seed={clip.seed} color={clip.selected ? "var(--mint-700)" : "var(--mint-500)"}
          style={waveStyle} intensity={0.85} density={1.4}
        />
      </div>
      <div style={{
        padding: "2px 6px 4px",
        fontFamily: APP_MONO_FONT, fontSize: 10, color: clip.selected ? "var(--mint-800)" : "var(--mint-700)",
        fontWeight: 600,
      }}>
        {clip.l.toFixed(1)}s
      </div>
    </div>
  );
}

function TrackHeaderRow({ id, dur, highlighted, narrow }) {
  return (
    <div style={{
      width: HEADER_W,
      height: TRACK_H,
      padding: narrow ? "10px 10px" : "12px 12px",
      borderBottom: "0.5px solid var(--border-1)",
      borderRight: "0.5px solid var(--border-1)",
      background: highlighted ? "var(--mint-50)" : "#fff",
      display: "flex", flexDirection: "column", justifyContent: "center",
      gap: 4,
    }}>
      <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
        <div style={{
          width: 20, height: 20, borderRadius: 6,
          background: highlighted ? "var(--mint-200)" : "var(--ink-100)",
          display: "flex", alignItems: "center", justifyContent: "center",
        }}>
          <Icon name="waveform" size={11} color={highlighted ? "var(--mint-700)" : "var(--fg-3)"}/>
        </div>
        <span style={{ fontFamily: APP_MONO_FONT, fontWeight: 700, fontSize: 12.5, color: "var(--fg-1)" }}>{id}</span>
      </div>
      <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
        <div style={{ fontFamily: APP_MONO_FONT, fontSize: 10, color: "var(--fg-3)" }}>{dur}</div>
      </div>
      {/* mini Solo/Mute */}
      <div style={{ display: "flex", gap: 4, marginTop: 2 }}>
        <span style={{ width: 18, height: 16, borderRadius: 4, background: "var(--ink-100)", color: "var(--fg-3)", fontSize: 9, fontWeight: 700, display: "flex", alignItems: "center", justifyContent: "center" }}>S</span>
        <span style={{ width: 18, height: 16, borderRadius: 4, background: "var(--ink-100)", color: "var(--fg-3)", fontSize: 9, fontWeight: 700, display: "flex", alignItems: "center", justifyContent: "center" }}>M</span>
      </div>
    </div>
  );
}

function PlayheadOverlay({ s = 38.42, height, pxPerS = PX_PER_S }) {
  const x = s * pxPerS;
  return (
    <div style={{
      position: "absolute", left: x, top: 0, bottom: 0, width: 2,
      pointerEvents: "none", zIndex: 10,
    }}>
      <div style={{ position: "absolute", left: -7, top: -2, width: 16, height: 12, background: "var(--sky-500)", clipPath: "polygon(50% 100%, 0 0, 100% 0)", filter: "drop-shadow(0 1px 2px rgba(42,163,245,0.4))" }}/>
      <div style={{ position: "absolute", left: 0, top: 0, bottom: 0, width: 2, background: "var(--sky-500)", boxShadow: "0 0 8px rgba(42,163,245,0.5)" }}/>
    </div>
  );
}

function TranscriptColumn({ trackId, lines, current }) {
  return (
    <div style={{
      flex: 1, minWidth: 0, display: "flex", flexDirection: "column",
      borderRight: "0.5px solid var(--border-1)",
      background: "var(--bg-1)",
    }}>
      <div style={{
        padding: "8px 12px",
        background: "var(--bg-2)",
        borderBottom: "0.5px solid var(--border-1)",
        display: "flex", alignItems: "center", gap: 8,
      }}>
        <Icon name="waveform" size={12} color="var(--mint-600)"/>
        <span style={{ fontFamily: APP_MONO_FONT, fontWeight: 700, fontSize: 12 }}>{trackId}</span>
        <Chip tone="success" style={{ marginLeft: "auto", padding: "1px 6px", fontSize: 10 }}>populated</Chip>
      </div>
      <div style={{ flex: 1, overflow: "auto", padding: "8px 6px" }}>
        {lines.map((l, i) => (
          <div key={i} style={{
            display: "flex", gap: 8, padding: "6px 8px",
            borderRadius: 6,
            background: l.current ? "var(--mint-50)" : "transparent",
            borderLeft: l.current ? "2px solid var(--mint-500)" : "2px solid transparent",
          }}>
            <span style={{ fontFamily: APP_MONO_FONT, fontSize: 10.5, color: "var(--fg-3)", flexShrink: 0, paddingTop: 2 }}>{formatTime(l.t)}</span>
            <span style={{ fontSize: 12.5, color: l.current ? "var(--fg-1)" : "var(--fg-2)", lineHeight: 1.45, fontWeight: l.current ? 500 : 400 }}>{l.text}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// Variants
// ─────────────────────────────────────────────────────────────

function SliceEditorA({ width = 1400, height = 880 }) {
  // A: Track headers LEFT, transcript RIGHT in a column
  const timelineW = 900;
  return (
    <MacShell width={width} height={height} title="Maycast Studio · Slice" subtitle="ep12-rust-rewrite">
      <EditorToolbar/>
      <div style={{ flex: 1, minHeight: 0, display: "flex" }}>
        {/* Timeline area (left) */}
        <div style={{ flex: 1, minWidth: 0, display: "flex", flexDirection: "column", background: "var(--bg-1)" }}>
          {/* ruler row */}
          <div style={{ display: "flex", flex: "0 0 auto" }}>
            <div style={{ width: HEADER_W, height: RULER_H, borderBottom: "0.5px solid var(--border-1)", borderRight: "0.5px solid var(--border-1)", background: "var(--ink-50)" }}/>
            <div style={{ flex: 1, overflow: "hidden", position: "relative" }}>
              <TimeRuler width={Math.max(timelineW, TIMELINE_LEN_S * PX_PER_S + 40)} />
            </div>
          </div>
          {/* Track rows */}
          <div style={{ flex: 1, overflow: "auto", position: "relative" }}>
            {TRACK_IDS.map((id) => (
              <div key={id} style={{ display: "flex" }}>
                <TrackHeaderRow id={id} dur={TRACKS.find(t => t.id === id).dur} highlighted={id === "host" || id === "guest"}/>
                <div style={{ flex: 1, position: "relative", height: TRACK_H, borderBottom: "0.5px solid var(--border-1)", background: id === "guest" ? "rgba(236,251,245,0.45)" : "transparent" }}>
                  {SLICE_CLIPS[id].map((c, i) => <ClipBlock key={i} clip={c} trackId={id} waveStyle="lines"/>)}
                </div>
              </div>
            ))}
            <PlayheadOverlay s={38.42} height={TRACK_H * 3}/>
          </div>
        </div>

        {/* Transcript panel right */}
        <div style={{
          flex: "0 0 360px",
          borderLeft: "0.5px solid var(--border-1)",
          display: "flex", flexDirection: "column",
          background: "var(--bg-2)",
        }}>
          <div style={{
            padding: "10px 14px",
            background: "linear-gradient(180deg, #fafdfc 0%, #f3f8f6 100%)",
            borderBottom: "0.5px solid var(--border-1)",
            display: "flex", alignItems: "center", gap: 10,
          }}>
            <Icon name="text.quote" size={14} color="var(--fg-2)"/>
            <span style={{ fontWeight: 700, fontSize: 13 }}>Transcript</span>
            <span style={{ fontSize: 11, color: "var(--fg-3)" }}>follow playhead</span>
            <div style={{ flex: 1 }}/>
            <Btn kind="ghost" size="sm" icon={<Icon name="waveform.badge.magnifyingglass" size={13}/>}>Re-transcribe</Btn>
          </div>
          <div style={{ flex: 1, minHeight: 0, overflow: "auto" }}>
            <TranscriptStacked/>
          </div>
        </div>
      </div>
    </MacShell>
  );
}

function TranscriptStacked() {
  return (
    <div style={{ padding: "8px 4px", display: "flex", flexDirection: "column", gap: 4 }}>
      {TRACK_IDS.map((id) => (
        <div key={id} style={{ padding: "6px 12px" }}>
          <div style={{ display: "flex", alignItems: "center", gap: 6, padding: "6px 0", borderBottom: "0.5px solid var(--ink-100)", marginBottom: 6 }}>
            <Icon name="waveform" size={11} color="var(--mint-600)"/>
            <span style={{ fontFamily: APP_MONO_FONT, fontWeight: 700, fontSize: 11.5 }}>{id}</span>
            <Chip tone="success" style={{ marginLeft: "auto", padding: "1px 6px", fontSize: 10 }}>populated</Chip>
          </div>
          {TRANSCRIPT[id].slice(0, 4).map((l, i) => (
            <div key={i} style={{ display: "flex", gap: 8, padding: "4px 0" }}>
              <span style={{ fontFamily: APP_MONO_FONT, fontSize: 10.5, color: "var(--fg-3)", flexShrink: 0, paddingTop: 2, width: 36 }}>{formatTime(l.t)}</span>
              <span style={{
                fontSize: 12, lineHeight: 1.4,
                color: l.current ? "var(--fg-1)" : "var(--fg-2)",
                fontWeight: l.current ? 600 : 400,
                background: l.current ? "var(--mint-50)" : "transparent",
                padding: l.current ? "2px 6px" : "0",
                marginLeft: l.current ? -6 : 0,
                borderRadius: l.current ? 4 : 0,
                borderLeft: l.current ? "2px solid var(--mint-500)" : "none",
              }}>{l.text}</span>
            </div>
          ))}
        </div>
      ))}
    </div>
  );
}

function SliceEditorB({ width = 1400, height = 880 }) {
  // B: Headers TOP per-track (no left column), transcript bottom panel, gradient waveforms
  return (
    <MacShell width={width} height={height} title="Maycast Studio · Slice" subtitle="ep12-rust-rewrite · layout B">
      <EditorToolbar variant="B"/>
      <div style={{ flex: 1, minHeight: 0, display: "flex", flexDirection: "column" }}>
        {/* Ruler */}
        <div style={{ flex: "0 0 auto", overflow: "hidden", position: "relative", background: "var(--ink-50)" }}>
          <TimeRuler width={TIMELINE_LEN_S * PX_PER_S + 40} />
        </div>

        {/* Tracks stacked, each with its own header strip on TOP */}
        <div style={{ flex: 1, overflow: "auto", background: "var(--bg-1)", position: "relative" }}>
          {TRACK_IDS.map((id) => {
            const dur = TRACKS.find((t) => t.id === id).dur;
            return (
              <div key={id} style={{ borderBottom: "0.5px solid var(--border-1)" }}>
                {/* track header strip on top */}
                <div style={{
                  display: "flex", alignItems: "center", gap: 10,
                  padding: "6px 12px",
                  background: "linear-gradient(90deg, var(--mint-50) 0%, transparent 30%)",
                  borderBottom: "0.5px solid var(--ink-100)",
                }}>
                  <div style={{
                    width: 22, height: 22, borderRadius: 6,
                    background: "var(--mint-200)", display: "flex", alignItems: "center", justifyContent: "center",
                  }}>
                    <Icon name="waveform" size={11} color="var(--mint-700)"/>
                  </div>
                  <span style={{ fontFamily: APP_MONO_FONT, fontWeight: 700, fontSize: 13 }}>{id}</span>
                  <span style={{ fontFamily: APP_MONO_FONT, fontSize: 11, color: "var(--fg-3)" }}>{dur}</span>
                  <div style={{ flex: 1 }}/>
                  <span style={{ fontSize: 11, color: "var(--fg-3)", fontFamily: APP_MONO_FONT }}>{SLICE_CLIPS[id].length} clips</span>
                  <ToolbarIconBtn icon="speaker.wave.2" small/>
                  <ToolbarIconBtn icon="ellipsis" small/>
                </div>
                {/* clips area */}
                <div style={{ position: "relative", height: TRACK_H - 10, background: "rgba(246,249,248,0.6)" }}>
                  {SLICE_CLIPS[id].map((c, i) => <ClipBlock key={i} clip={c} trackId={id} waveStyle="gradient"/>)}
                </div>
              </div>
            );
          })}
          <PlayheadOverlay s={38.42}/>
        </div>

        {/* Transcript bottom */}
        <div style={{
          flex: "0 0 220px",
          borderTop: "0.5px solid var(--border-1)",
          display: "flex", flexDirection: "column",
          background: "var(--bg-2)",
        }}>
          <div style={{
            padding: "8px 14px",
            display: "flex", alignItems: "center", gap: 10,
            background: "linear-gradient(180deg, #fafdfc 0%, #f3f8f6 100%)",
            borderBottom: "0.5px solid var(--border-1)",
          }}>
            <Icon name="text.quote" size={14} color="var(--fg-2)"/>
            <span style={{ fontWeight: 700, fontSize: 13 }}>Transcript</span>
            <div style={{ flex: 1 }}/>
            <Btn kind="ghost" size="sm" icon={<Icon name="waveform.badge.magnifyingglass" size={13}/>}>Re-transcribe all</Btn>
            <Btn kind="ghost" size="sm" icon={<Icon name="xmark" size={12}/>}/>
          </div>
          <div style={{ flex: 1, overflow: "hidden", display: "flex" }}>
            {TRACK_IDS.map((id) => (
              <TranscriptColumn key={id} trackId={id} lines={TRANSCRIPT[id]} />
            ))}
          </div>
        </div>
      </div>
    </MacShell>
  );
}

function SliceEditorC({ width = 1400, height = 880 }) {
  // C: Headers LEFT, no transcript panel by default, BLOCK waveforms, denser look
  return (
    <MacShell width={width} height={height} title="Maycast Studio · Slice" subtitle="ep12-rust-rewrite · layout C">
      <EditorToolbar variant="C" transcriptOpen={false}/>
      <div style={{ flex: 1, minHeight: 0, display: "flex", background: "var(--ink-50)" }}>
        <div style={{ flex: 1, minWidth: 0, display: "flex", flexDirection: "column" }}>
          {/* ruler row */}
          <div style={{ display: "flex", flex: "0 0 auto" }}>
            <div style={{ width: HEADER_W, height: RULER_H, borderBottom: "0.5px solid var(--border-1)", borderRight: "0.5px solid var(--border-1)", background: "var(--ink-50)" }}/>
            <div style={{ flex: 1, overflow: "hidden", position: "relative" }}>
              <TimeRuler width={TIMELINE_LEN_S * PX_PER_S + 40} />
            </div>
          </div>

          {/* tracks */}
          <div style={{ flex: 1, overflow: "auto", position: "relative", background: "#0e1f1a" }}>
            {TRACK_IDS.map((id, idx) => (
              <div key={id} style={{ display: "flex" }}>
                <div style={{
                  width: HEADER_W,
                  height: TRACK_H,
                  borderBottom: "0.5px solid rgba(255,255,255,0.06)",
                  borderRight: "0.5px solid rgba(255,255,255,0.08)",
                  background: idx === 0 ? "rgba(31,194,152,0.15)" : "rgba(255,255,255,0.03)",
                  padding: "12px",
                  display: "flex", flexDirection: "column", justifyContent: "center", gap: 4,
                }}>
                  <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
                    <div style={{
                      width: 20, height: 20, borderRadius: 6,
                      background: idx === 0 ? "var(--mint-500)" : "rgba(255,255,255,0.08)",
                      display: "flex", alignItems: "center", justifyContent: "center",
                    }}>
                      <Icon name="waveform" size={11} color={idx === 0 ? "#fff" : "rgba(255,255,255,0.55)"}/>
                    </div>
                    <span style={{ fontFamily: APP_MONO_FONT, fontWeight: 700, fontSize: 12.5, color: "rgba(255,255,255,0.95)" }}>{id}</span>
                  </div>
                  <div style={{ fontFamily: APP_MONO_FONT, fontSize: 10, color: "rgba(255,255,255,0.5)" }}>{TRACKS.find((t) => t.id === id).dur}</div>
                </div>
                <div style={{ flex: 1, position: "relative", height: TRACK_H, borderBottom: "0.5px solid rgba(255,255,255,0.06)" }}>
                  {SLICE_CLIPS[id].map((c, i) => (
                    <div key={i} style={{
                      position: "absolute",
                      left: c.s * PX_PER_S, top: 8,
                      width: c.l * PX_PER_S, height: TRACK_H - 16,
                      background: c.selected
                        ? "linear-gradient(180deg, rgba(61,217,176,0.35), rgba(31,194,152,0.18))"
                        : "rgba(31,194,152,0.10)",
                      border: c.selected ? "1.5px solid var(--mint-400)" : "0.5px solid rgba(61,217,176,0.35)",
                      borderRadius: 7,
                      overflow: "hidden",
                      display: "flex", flexDirection: "column",
                    }}>
                      <div style={{ flex: 1, padding: 4, display: "flex", alignItems: "center" }}>
                        <Waveform
                          width={Math.max(20, c.l * PX_PER_S - 8)} height={TRACK_H - 36}
                          seed={c.seed}
                          color={c.selected ? "#7df0c8" : "#3dd9b0"}
                          style="blocks" density={1.4} intensity={0.95}
                        />
                      </div>
                      <div style={{ padding: "1px 6px 4px", fontFamily: APP_MONO_FONT, fontSize: 10, color: c.selected ? "#a8f3d5" : "rgba(61,217,176,0.75)", fontWeight: 600 }}>{c.l.toFixed(1)}s</div>
                    </div>
                  ))}
                </div>
              </div>
            ))}
            {/* Playhead — sky overlay */}
            <div style={{ position: "absolute", left: 38.42 * PX_PER_S, top: 0, bottom: 0, width: 2, background: "var(--sky-400)", boxShadow: "0 0 12px rgba(77,188,255,0.7)", pointerEvents: "none" }}>
              <div style={{ position: "absolute", left: -7, top: -2, width: 16, height: 12, background: "var(--sky-400)", clipPath: "polygon(50% 100%, 0 0, 100% 0)" }}/>
            </div>
          </div>
        </div>
      </div>
    </MacShell>
  );
}

Object.assign(window, { SliceEditorA, SliceEditorB, SliceEditorC, SLICE_CLIPS, TRANSCRIPT });
