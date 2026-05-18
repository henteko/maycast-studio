// misc.jsx — History sheet + Error view

const HISTORY_APPLIED = [
  {
    kind: "polish",
    tracks: ["host", "guest", "remote"],
    when: "2 minutes ago",
    diffs: [
      { id: "host",   from: "intermediate/host/002_slice.wav",   to: "intermediate/host/003_polish.wav" },
      { id: "guest",  from: "intermediate/guest/001_slice.wav",  to: "intermediate/guest/002_polish.wav" },
      { id: "remote", from: "sources/remote.wav",                to: "intermediate/remote/001_polish.wav" },
    ],
  },
  {
    kind: "slice",
    tracks: ["host", "guest"],
    when: "11 minutes ago",
    diffs: [
      { id: "host",  from: "intermediate/host/001_slice.wav",  to: "intermediate/host/002_slice.wav" },
      { id: "guest", from: "sources/guest.wav",                to: "intermediate/guest/001_slice.wav" },
    ],
  },
  {
    kind: "polish",
    tracks: ["host"],
    when: "1 hour ago",
    diffs: [
      { id: "host", from: "sources/host.wav", to: "intermediate/host/001_slice.wav" },
    ],
  },
  {
    kind: "slice",
    tracks: ["host", "guest", "remote"],
    when: "1 hour ago",
    diffs: [
      { id: "host",   from: "sources/host.wav",   to: "intermediate/host/001_pre.wav" },
      { id: "guest",  from: "sources/guest.wav",  to: "intermediate/guest/001_pre.wav" },
      { id: "remote", from: "sources/remote.wav", to: "intermediate/remote/001_pre.wav" },
    ],
  },
];

const HISTORY_REDO = [
  {
    kind: "slice",
    tracks: ["remote"],
    when: "23 minutes ago",
    diffs: [
      { id: "remote", from: "intermediate/remote/001_pre.wav", to: "intermediate/remote/002_slice.wav" },
    ],
  },
];

function HistorySheet() {
  return (
    <SheetFrame
      width={760}
      minHeight={700}
      title="Episode History"
      subtitle="Every Slice / Polish / Mix batch is recorded. Undo and Redo both walk this list."
      rightHeader={
        <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
          <Btn kind="ghost" size="sm">
            Close
            <KeyHint label="⎋"/>
          </Btn>
        </div>
      }
    >
      <div style={{ display: "flex", flexDirection: "column", gap: 18 }}>
        <div>
          <div style={{ display: "flex", alignItems: "baseline", gap: 8, marginBottom: 10 }}>
            <h3 style={{ fontFamily: APP_DISPLAY_FONT, fontSize: 14, fontWeight: 700, margin: 0 }}>Applied</h3>
            <span style={{ fontSize: 12, color: "var(--fg-3)" }}>Newest first — {HISTORY_APPLIED.length} batches</span>
          </div>
          <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
            {HISTORY_APPLIED.map((b, i) => <HistoryCard key={i} batch={b}/>)}
          </div>
        </div>

        <div>
          <div style={{ display: "flex", alignItems: "baseline", gap: 8, marginBottom: 10 }}>
            <h3 style={{ fontFamily: APP_DISPLAY_FONT, fontSize: 14, fontWeight: 700, margin: 0 }}>Available to redo</h3>
            <span style={{ fontSize: 12, color: "var(--fg-3)" }}>{HISTORY_REDO.length} batch · undone</span>
          </div>
          <div style={{ display: "flex", flexDirection: "column", gap: 10, opacity: 0.55 }}>
            {HISTORY_REDO.map((b, i) => <HistoryCard key={i} batch={b}/>)}
          </div>
        </div>
      </div>
    </SheetFrame>
  );
}

function HistoryCard({ batch }) {
  const meta = ACTIVITY_META[batch.kind];
  return (
    <div style={{
      padding: "14px 16px",
      background: "var(--bg-1)",
      border: "0.5px solid var(--border-1)",
      borderRadius: 12,
      boxShadow: "var(--shadow-xs)",
      display: "flex", flexDirection: "column", gap: 10,
    }}>
      <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
        <div style={{
          width: 30, height: 30, borderRadius: 8,
          background: `var(--${meta.tone}-50)`,
          display: "flex", alignItems: "center", justifyContent: "center",
        }}>
          <Icon name={meta.icon} size={14} color={`var(--${meta.tone}-700)`}/>
        </div>
        <div style={{ flex: 1 }}>
          <div style={{ display: "flex", alignItems: "baseline", gap: 6 }}>
            <span style={{ fontWeight: 700, fontSize: 13.5 }}>{meta.label}</span>
            <span style={{ fontSize: 11.5, color: "var(--fg-3)", fontFamily: APP_MONO_FONT }}>{batch.tracks.join(", ")}</span>
          </div>
        </div>
        <span style={{ fontSize: 11.5, color: "var(--fg-3)" }}>{batch.when}</span>
      </div>
      <div style={{
        padding: "10px 12px",
        background: "var(--bg-2)",
        borderRadius: 8,
        display: "flex", flexDirection: "column", gap: 4,
        fontFamily: APP_MONO_FONT, fontSize: 11,
      }}>
        {batch.diffs.map((d) => (
          <div key={d.id} style={{ display: "flex", gap: 8, alignItems: "baseline" }}>
            <span style={{ width: 56, fontWeight: 700, color: "var(--fg-1)" }}>{d.id}</span>
            <span style={{ color: "var(--fg-3)" }}>{d.from}</span>
            <span style={{ color: "var(--fg-4)" }}>→</span>
            <span style={{ color: "var(--mint-700)" }}>{d.to}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

function ErrorView() {
  return (
    <MacShell width={720} height={500} title="Maycast Studio" menubar={false}>
      <div style={{
        flex: 1, minHeight: 0,
        background: "linear-gradient(180deg, #fff7e6 0%, #ffffff 50%)",
        padding: "48px 56px",
        display: "flex", flexDirection: "column", alignItems: "center",
        textAlign: "center", gap: 18,
      }}>
        <div style={{
          width: 72, height: 72, borderRadius: 18,
          background: "linear-gradient(180deg, #fff0d0 0%, #ffd994 100%)",
          display: "flex", alignItems: "center", justifyContent: "center",
          boxShadow: "0 4px 16px rgba(245,158,11,0.25)",
        }}>
          <Icon name="exclamationmark.triangle" size={36} color="#c4760a"/>
        </div>
        <div>
          <h2 style={{ fontFamily: APP_DISPLAY_FONT, fontSize: 22, fontWeight: 700, margin: 0 }}>Failed to open Episode</h2>
          <p style={{ fontSize: 13.5, color: "var(--fg-2)", margin: "8px 0 0", maxWidth: 480, lineHeight: 1.5 }}>
            Maycast Studio couldn’t read the bundle at the path below. The file may be from a newer version, corrupted, or moved.
          </p>
        </div>
        <div style={{
          padding: "14px 18px",
          background: "var(--bg-2)",
          border: "0.5px solid var(--border-1)",
          borderRadius: 10,
          fontFamily: APP_MONO_FONT, fontSize: 11.5,
          color: "var(--fg-2)",
          maxWidth: 560,
          textAlign: "left",
          width: "100%",
        }}>
          <div style={{ color: "var(--fg-3)", marginBottom: 4 }}>~/Podcasts/code-and-coffee/ep12-rust-rewrite.maycast</div>
          <div>
            <span style={{ color: "var(--danger)", fontWeight: 600 }}>Error:</span> manifest.json: unexpected token at line 14, column 9
          </div>
          <div style={{ color: "var(--fg-3)", marginTop: 4 }}>↳ expected a key, found “]”</div>
        </div>
        <div style={{ display: "flex", gap: 10, marginTop: 6 }}>
          <Btn kind="secondary" icon={<Icon name="folder" size={13}/>}>Reveal in Finder</Btn>
          <Btn kind="primary" glow>Dismiss</Btn>
        </div>
      </div>
    </MacShell>
  );
}

Object.assign(window, { HistorySheet, ErrorView });
