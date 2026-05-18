// episode.jsx — Episode workspace shell

const EP = {
  id: "ep12-rust-rewrite",
  uuid: "8a3f2e10-c4b7-4d1a-9e0e-3f1b8c7d4a92",
  show: "code & coffee",
  path: "~/Podcasts/Code & Coffee/ep12-rust-rewrite.maycast",
};

const TRACKS = [
  { id: "host",   source: "sources/host.wav",   current: "intermediate/host/003_polish.wav",   gens: 3, dur: "38:51.61" },
  { id: "guest",  source: "sources/guest.wav",  current: "intermediate/guest/002_polish.wav",  gens: 2, dur: "38:42.18" },
  { id: "remote", source: "sources/remote.wav", current: "intermediate/remote/001_polish.wav", gens: 1, dur: "37:55.04" },
];

const ACTIVITY = [
  { kind: "polish", tracks: ["host","guest","remote"], when: "2 minutes ago" },
  { kind: "slice",  tracks: ["host","guest"], when: "11 minutes ago" },
  { kind: "slice",  tracks: ["remote"], when: "23 minutes ago", undone: true },
  { kind: "polish", tracks: ["host"], when: "1 hour ago" },
  { kind: "slice",  tracks: ["host","guest","remote"], when: "1 hour ago" },
];

const ACTIVITY_META = {
  slice:  { label: "Slice",  icon: "scissors",         tone: "sky"  },
  polish: { label: "Polish", icon: "wand.and.sparkles", tone: "mint" },
  mix:    { label: "Mix",    icon: "rectangle.stack",  tone: "sun"  },
};

function EpisodeView() {
  return (
    <MacShell width={1280} height={820} title="Maycast Studio" subtitle={EP.id}>
      <div style={{ flex: 1, minHeight: 0, display: "flex", flexDirection: "column", background: "var(--bg-1)" }}>
        {/* Header band */}
        <div style={{
          padding: "26px 32px 22px",
          background: "linear-gradient(180deg, var(--mint-50) 0%, #ffffff 100%)",
          borderBottom: "0.5px solid var(--border-1)",
          display: "flex", alignItems: "flex-start", gap: 24,
        }}>
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ display: "flex", alignItems: "center", gap: 10, marginBottom: 8 }}>
              <Chip tone="mint" icon={<Icon name="shippingbox" size={11} color="var(--mint-700)"/>}>code & coffee</Chip>
              <Chip tone="neutral">3 tracks</Chip>
              <Chip tone="neutral" icon={<Icon name="clock" size={11}/>}>38:51</Chip>
            </div>
            <h1 style={{
              fontFamily: APP_DISPLAY_FONT, fontSize: 28, fontWeight: 900, margin: 0,
              letterSpacing: "-0.01em", color: "var(--ink-900)",
            }}>{EP.id}</h1>
            <div style={{ fontFamily: APP_MONO_FONT, fontSize: 11, color: "var(--fg-3)", marginTop: 6, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
              {EP.path}
            </div>
          </div>
          <div style={{ textAlign: "right", flexShrink: 0 }}>
            <div style={{ fontSize: 10.5, color: "var(--fg-3)", textTransform: "uppercase", letterSpacing: "0.08em", fontWeight: 700 }}>UUID</div>
            <div style={{ fontFamily: APP_MONO_FONT, fontSize: 11, color: "var(--fg-3)", marginTop: 4 }}>{EP.uuid}</div>
          </div>
        </div>

        {/* Body: tracks + activity */}
        <div style={{ flex: 1, minHeight: 0, display: "flex" }}>
          {/* Tracks */}
          <div style={{ flex: 1.4, minWidth: 0, padding: "22px 32px", overflow: "auto" }}>
            <div style={{ display: "flex", alignItems: "baseline", gap: 10, marginBottom: 14 }}>
              <h2 style={{ fontFamily: APP_DISPLAY_FONT, fontSize: 16, fontWeight: 700, margin: 0 }}>Tracks</h2>
              <span style={{ fontSize: 12, color: "var(--fg-3)" }}>{TRACKS.length} sources</span>
            </div>
            <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
              {TRACKS.map((t) => <TrackCard key={t.id} t={t}/>)}
            </div>
          </div>

          {/* Recent activity */}
          <div style={{
            flex: 1, minWidth: 0,
            padding: "22px 32px 22px 0",
            display: "flex", flexDirection: "column",
          }}>
            <div style={{ display: "flex", alignItems: "center", gap: 10, marginBottom: 14 }}>
              <Icon name="clock.arrow.circlepath" size={15} color="var(--fg-2)"/>
              <h2 style={{ fontFamily: APP_DISPLAY_FONT, fontSize: 16, fontWeight: 700, margin: 0 }}>Recent activity</h2>
              <span style={{ fontSize: 12, color: "var(--fg-3)" }}>(14 total)</span>
              <div style={{ flex: 1 }}/>
              <a style={{ fontSize: 12.5, color: "var(--mint-700)", fontWeight: 600 }}>Show all…</a>
            </div>
            <div style={{
              flex: 1, minHeight: 0,
              background: "var(--bg-2)",
              border: "0.5px solid var(--border-1)",
              borderRadius: 12,
              padding: 8,
              display: "flex", flexDirection: "column", gap: 2,
            }}>
              {ACTIVITY.map((a, i) => <ActivityRow key={i} a={a}/>)}
            </div>
          </div>
        </div>

        {/* Action bar */}
        <ActionBar/>
      </div>
    </MacShell>
  );
}

function TrackCard({ t }) {
  return (
    <div style={{
      padding: "14px 18px",
      background: "#fff",
      border: "0.5px solid var(--border-1)",
      borderRadius: 12,
      boxShadow: "var(--shadow-xs)",
      display: "flex", alignItems: "center", gap: 16,
    }}>
      <div style={{
        flex: "0 0 44px", height: 44, borderRadius: 10,
        background: "var(--mint-50)",
        display: "flex", alignItems: "center", justifyContent: "center",
        border: "0.5px solid var(--mint-200)",
      }}>
        <Icon name="waveform" size={20} color="var(--mint-600)"/>
      </div>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ display: "flex", alignItems: "baseline", gap: 8 }}>
          <span style={{ fontFamily: APP_MONO_FONT, fontWeight: 700, fontSize: 13.5, color: "var(--fg-1)" }}>{t.id}</span>
          <Chip tone="neutral" style={{ padding: "1px 7px", fontSize: 10.5 }}>{t.gens} generation{t.gens === 1 ? "" : "s"}</Chip>
          <span style={{ fontFamily: APP_MONO_FONT, fontSize: 11.5, color: "var(--fg-3)", marginLeft: "auto" }}>{t.dur}</span>
        </div>
        <div style={{ display: "flex", flexDirection: "column", gap: 2, marginTop: 6 }}>
          <span style={{ fontFamily: APP_MONO_FONT, fontSize: 11, color: "var(--fg-3)" }}>source: {t.source}</span>
          <span style={{ fontFamily: APP_MONO_FONT, fontSize: 11, color: "var(--fg-3)" }}>current: {t.current}</span>
        </div>
      </div>
      <div style={{ width: 220, height: 36 }}>
        <Waveform width={220} height={36} seed={t.id.length * 7 + 3} color="var(--mint-400)" style="blocks" intensity={0.7} density={1.2}/>
      </div>
    </div>
  );
}

function ActivityRow({ a }) {
  const meta = ACTIVITY_META[a.kind];
  return (
    <div style={{
      padding: "9px 12px",
      display: "flex", alignItems: "center", gap: 10,
      borderRadius: 8,
      opacity: a.undone ? 0.55 : 1,
    }}>
      <div style={{
        width: 26, height: 26, borderRadius: 7,
        background: `var(--${meta.tone}-50, var(--ink-100))`,
        display: "flex", alignItems: "center", justifyContent: "center",
      }}>
        <Icon name={meta.icon} size={13} color={`var(--${meta.tone}-700)`}/>
      </div>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ display: "flex", alignItems: "baseline", gap: 6 }}>
          <span style={{ fontWeight: 600, fontSize: 12.5, color: "var(--fg-1)" }}>{meta.label}</span>
          {a.undone && <span style={{ fontSize: 11, color: "var(--fg-3)", fontStyle: "italic" }}>(undone)</span>}
        </div>
        <div style={{ fontFamily: APP_MONO_FONT, fontSize: 11, color: "var(--fg-3)" }}>{a.tracks.join(", ")}</div>
      </div>
      <span style={{ fontSize: 11, color: "var(--fg-3)" }}>{a.when}</span>
    </div>
  );
}

function ActionBar() {
  return (
    <div style={{
      flex: "0 0 auto",
      padding: "10px 24px",
      borderTop: "0.5px solid var(--border-1)",
      background: "linear-gradient(180deg, rgba(255,255,255,0.6) 0%, rgba(246,249,248,0.85) 100%)",
      backdropFilter: "blur(20px)",
      display: "flex", alignItems: "center", gap: 8,
    }}>
      <Btn kind="secondary" size="md" icon={<Icon name="arrow.uturn.backward" size={14}/>}>
        Undo polish
        <KeyHint mod label="Z"/>
      </Btn>
      <Btn kind="secondary" size="md" icon={<Icon name="arrow.uturn.forward" size={14}/>}>
        Redo
        <KeyHint mod shift label="Z"/>
      </Btn>
      <div style={{ width: 1, height: 22, background: "var(--border-1)", margin: "0 6px" }}/>
      <Btn kind="secondary" size="md" icon={<Icon name="scissors" size={14} color="var(--sky-600)"/>}>
        Slice
        <span style={{ fontSize: 11, color: "var(--fg-3)", fontWeight: 500, marginLeft: 4 }}>multi-track</span>
      </Btn>
      <Btn kind="secondary" size="md" icon={<Icon name="wand.and.sparkles" size={14} color="var(--mint-600)"/>}>
        Polish
        <span style={{ fontSize: 11, color: "var(--fg-3)", fontWeight: 500, marginLeft: 4 }}>multi-track</span>
      </Btn>
      <div style={{ flex: 1 }}/>
      <Btn kind="primary" size="md" glow icon={<Icon name="square.stack.3d.down.forward" size={15} color="#fff"/>}>
        Mix
      </Btn>
    </div>
  );
}

Object.assign(window, { EpisodeView, TRACKS, ACTIVITY, ACTIVITY_META, EP });
