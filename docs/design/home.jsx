// home.jsx — Home screen variants
// A: Warm welcome — generous hero with illustration & soft mint gradient
// B: All-business — compact workspace, recent list dominates

const { useMemo: _useMemo_home } = React;

// Calm, declarative, on-brand greetings. Picked once per mount.
const GREETINGS = [
  "Welcome back.",
  "Ready when you are.",
  "Studio’s open.",
  "Pick up where you left off.",
  "Today’s tape is waiting.",
  "Where were we?",
  "Hello again.",
  "All ears.",
  "Tape rolls when you do.",
  "Press record when you’re ready.",
  "Take your time.",
  "Coffee’s on. Faders up.",
  "Quiet the noise. Keep the voice.",
  "One more for the feed.",
  "Make today’s episode lighter.",
  "Less knobs. More conversation.",
  "Sounds like a good day to publish.",
  "A quieter way to ship.",
  "Today, something worth listening to.",
  "Cleared and ready.",
];

const RECENTS = [
  { id: "ep-12", name: "ep12-rust-rewrite", show: "code & coffee", path: "~/Podcasts/Code & Coffee/ep12-rust-rewrite.maycast",  when: "2 minutes ago",  tracks: 3 },
  { id: "ep-11", name: "ep11-team-rituals", show: "code & coffee", path: "~/Podcasts/Code & Coffee/ep11-team-rituals.maycast",   when: "yesterday",     tracks: 3 },
  { id: "ep-10", name: "ep10-postmortem",   show: "code & coffee", path: "~/Podcasts/Code & Coffee/ep10-postmortem.maycast",     when: "3 days ago",    tracks: 4 },
  { id: "tn-04", name: "tn04-shipping",     show: "the night shift", path: "~/Podcasts/Night Shift/tn04-shipping.maycast",       when: "last week",     tracks: 2 },
  { id: "tn-03", name: "tn03-ramen-talk",   show: "the night shift", path: "~/Podcasts/Night Shift/tn03-ramen-talk.maycast",     when: "Apr 28",        tracks: 2 },
  { id: "lo-02", name: "lo02-q1-recap",     show: "looseleaf",        path: "~/Podcasts/Looseleaf/lo02-q1-recap.maycast",         when: "Apr 12",        tracks: 5 },
];

// ─────────────────────────────────────────────────────────────
// A · Warm welcome
// ─────────────────────────────────────────────────────────────
function HomeWarm() {
  const phrase = _useMemo_home(() => GREETINGS[Math.floor(Math.random() * GREETINGS.length)], []);
  return (
    <MacShell width={1280} height={820} title="Maycast Studio">
      <div style={{
        flex: 1, minHeight: 0,
        background: "linear-gradient(180deg, #eaf9f3 0%, #e8f4fa 55%, #ffffff 100%)",
        position: "relative",
        overflow: "hidden",
        display: "flex", flexDirection: "column",
      }}>
        {/* Decorative clouds */}
        <Cloud style={{ position: "absolute", top: 60, left: 80, width: 220, opacity: 0.55 }}/>
        <Cloud style={{ position: "absolute", top: 130, right: 120, width: 180, opacity: 0.45 }}/>
        <Cloud style={{ position: "absolute", top: 280, left: 320, width: 140, opacity: 0.35 }}/>

        {/* Top band: logo + rotating phrase + actions */}
        <div style={{
          padding: "56px 80px 32px",
          display: "flex", alignItems: "center", gap: 32,
          position: "relative", zIndex: 2,
        }}>
          <LogoMark size={48}/>
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{
              fontFamily: APP_DISPLAY_FONT,
              fontSize: 32, fontWeight: 700,
              lineHeight: 1.2, letterSpacing: "-0.01em",
              color: "var(--ink-900)",
              textWrap: "balance",
            }} key={phrase}>
              {phrase}
            </div>
          </div>
          <div style={{ display: "flex", gap: 8, alignSelf: "center" }}>
            <Btn kind="primary" glow icon={<Icon name="plus.rectangle" size={15} color="#fff"/>}>
              New Episode
              <KeyHint mod label="N"/>
            </Btn>
            <Btn kind="secondary" icon={<Icon name="shippingbox" size={14}/>}>
              New Show
              <KeyHint mod shift label="N"/>
            </Btn>
            <Btn kind="secondary" icon={<Icon name="folder" size={14}/>}>
              Open
              <KeyHint mod label="O"/>
            </Btn>
          </div>
        </div>

        {/* Recents */}
        <div style={{ flex: 1, minHeight: 0, padding: "8px 80px 56px", position: "relative", zIndex: 2, display: "flex", flexDirection: "column" }}>
          <div style={{ display: "flex", alignItems: "baseline", gap: 10, marginBottom: 18 }}>
            <Icon name="clock" size={16} color="var(--fg-2)"/>
            <h2 style={{ fontFamily: APP_DISPLAY_FONT, fontSize: 20, fontWeight: 700, margin: 0, color: "var(--fg-1)" }}>Recent episodes</h2>
            <span style={{ fontSize: 12, color: "var(--fg-3)" }}>(6 total)</span>
          </div>
          <div style={{
            display: "grid", gridTemplateColumns: "repeat(3, 1fr)", gap: 14,
          }}>
            {RECENTS.slice(0, 6).map((r) => (
              <RecentCard key={r.id} ep={r}/>
            ))}
          </div>
        </div>
      </div>
    </MacShell>
  );
}

function RecentCard({ ep }) {
  return (
    <div style={{
      padding: "14px 16px",
      background: "rgba(255,255,255,0.85)",
      backdropFilter: "blur(8px)",
      borderRadius: 14,
      border: "0.5px solid var(--border-1)",
      boxShadow: "var(--shadow-xs)",
      display: "flex", gap: 12,
      cursor: "pointer",
      transition: "all 120ms var(--ease-out)",
    }}>
      <div style={{
        flex: "0 0 38px", height: 38, borderRadius: 10,
        background: "linear-gradient(180deg, var(--mint-100), var(--mint-200))",
        display: "flex", alignItems: "center", justifyContent: "center",
      }}>
        <Icon name="rectangle.stack.fill" size={18} color="var(--mint-700)"/>
      </div>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ display: "flex", alignItems: "baseline", gap: 6 }}>
          <div style={{ fontWeight: 700, fontSize: 14, color: "var(--fg-1)", letterSpacing: "-0.005em" }}>{ep.name}</div>
        </div>
        <div style={{ fontSize: 12, color: "var(--fg-3)", marginTop: 2 }}>· {ep.show}</div>
        <div style={{ fontFamily: APP_MONO_FONT, fontSize: 10.5, color: "var(--fg-4)", marginTop: 6, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{ep.path}</div>
        <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", marginTop: 6 }}>
          <span style={{ fontSize: 11, color: "var(--fg-3)" }}>{ep.when}</span>
          <span style={{ fontSize: 10.5, color: "var(--fg-4)", fontFamily: APP_MONO_FONT }}>{ep.tracks} tracks</span>
        </div>
      </div>
    </div>
  );
}

// Keyboard shortcut hint
function KeyHint({ mod, shift, alt, label }) {
  const keys = [];
  if (alt) keys.push("⌥");
  if (shift) keys.push("⇧");
  if (mod) keys.push("⌘");
  keys.push(label);
  return (
    <span style={{
      marginLeft: 4,
      fontFamily: APP_MONO_FONT,
      fontSize: 10.5,
      fontWeight: 600,
      opacity: 0.7,
      padding: "1px 5px",
      borderRadius: 4,
      background: "rgba(255,255,255,0.18)",
    }}>{keys.join("")}</span>
  );
}

function Cloud({ style }) {
  return (
    <svg viewBox="0 0 200 80" style={style} preserveAspectRatio="xMidYMid meet">
      <path d="M30 60 Q15 60 15 45 Q15 32 30 32 Q32 18 50 18 Q66 14 76 24 Q90 18 102 28 Q120 22 130 36 Q150 32 160 46 Q172 50 172 60 Z" fill="#ffffff" fillOpacity="0.85"/>
    </svg>
  );
}

// ─────────────────────────────────────────────────────────────
// B · All-business workspace
// Compact header, dense recents table, no hero.
// ─────────────────────────────────────────────────────────────
function HomeWork() {
  return (
    <MacShell width={1280} height={820} title="Maycast Studio">
      <div style={{ flex: 1, minHeight: 0, background: "var(--bg-1)", display: "flex", flexDirection: "column" }}>
        {/* Quick action toolbar */}
        <div style={{
          padding: "16px 24px",
          borderBottom: "0.5px solid var(--border-1)",
          display: "flex", alignItems: "center", gap: 12,
          background: "linear-gradient(180deg, #fafdfc 0%, #ffffff 100%)",
        }}>
          <LogoMark size={28}/>
          <div style={{ display: "flex", flexDirection: "column", lineHeight: 1.1 }}>
            <span style={{ fontFamily: APP_DISPLAY_FONT, fontWeight: 700, fontSize: 14, letterSpacing: "-0.005em" }}>Maycast Studio</span>
            <span style={{ fontSize: 11, color: "var(--fg-3)" }}>Open a recent episode, or start a fresh one.</span>
          </div>
          <div style={{ flex: 1 }}/>
          <Btn kind="primary" icon={<Icon name="plus.rectangle" size={15} color="#fff"/>}>
            New Episode…
          </Btn>
          <Btn kind="secondary" icon={<Icon name="shippingbox" size={14}/>}>
            New Show…
          </Btn>
          <Btn kind="secondary" icon={<Icon name="folder" size={14}/>}>
            Open…
          </Btn>
        </div>

        {/* Two-column body */}
        <div style={{ flex: 1, minHeight: 0, display: "flex" }}>
          {/* Sidebar: shows */}
          <div style={{
            width: 240, padding: "20px 16px",
            background: "var(--bg-2)",
            borderRight: "0.5px solid var(--border-1)",
            display: "flex", flexDirection: "column", gap: 4,
          }}>
            <div style={{ fontSize: 10.5, fontWeight: 700, color: "var(--fg-3)", textTransform: "uppercase", letterSpacing: "0.08em", padding: "4px 8px 6px" }}>Shows</div>
            <ShowRow name="code & coffee"   count={12} selected/>
            <ShowRow name="the night shift" count={4}/>
            <ShowRow name="looseleaf"       count={2}/>
            <div style={{ marginTop: 14, fontSize: 10.5, fontWeight: 700, color: "var(--fg-3)", textTransform: "uppercase", letterSpacing: "0.08em", padding: "4px 8px 6px" }}>Library</div>
            <ShowRow name="All episodes" count={18} icon="rectangle.stack"/>
            <ShowRow name="Drafts"       count={2}  icon="text.quote"/>
            <ShowRow name="Exports"      count={31} icon="square.stack.3d.down.forward"/>
          </div>

          {/* Main: recent table */}
          <div style={{ flex: 1, minWidth: 0, display: "flex", flexDirection: "column" }}>
            <div style={{
              padding: "16px 24px 12px",
              display: "flex", alignItems: "center", gap: 12,
            }}>
              <h2 style={{ fontFamily: APP_DISPLAY_FONT, fontSize: 17, fontWeight: 700, margin: 0 }}>Recent episodes</h2>
              <span style={{ fontSize: 12, color: "var(--fg-3)" }}>6 total</span>
              <div style={{ flex: 1 }}/>
              <div style={{
                display: "flex", alignItems: "center", gap: 6,
                padding: "5px 10px", borderRadius: 8,
                background: "var(--bg-2)", border: "0.5px solid var(--border-1)",
                width: 200,
              }}>
                <Icon name="magnifyingglass" size={13} color="var(--fg-3)"/>
                <span style={{ fontSize: 12, color: "var(--fg-4)" }}>Filter episodes…</span>
              </div>
              <Btn kind="ghost" size="sm" icon={<Icon name="ellipsis" size={14}/>}/>
            </div>

            {/* Table */}
            <div style={{ flex: 1, padding: "0 12px 16px", overflow: "auto" }}>
              <div style={{
                display: "grid",
                gridTemplateColumns: "minmax(0,1.6fr) minmax(0,1.4fr) 100px 130px 60px",
                padding: "8px 16px",
                fontSize: 10.5, fontWeight: 700, color: "var(--fg-3)", textTransform: "uppercase", letterSpacing: "0.06em",
                borderBottom: "0.5px solid var(--border-1)",
              }}>
                <span>Episode</span>
                <span>Path</span>
                <span>Tracks</span>
                <span>Last opened</span>
                <span style={{ textAlign: "right" }}> </span>
              </div>
              {RECENTS.map((r, i) => (
                <RecentRow key={r.id} ep={r} alt={i % 2 === 1}/>
              ))}
            </div>
          </div>
        </div>
      </div>
    </MacShell>
  );
}

function ShowRow({ name, count, selected, icon }) {
  return (
    <div style={{
      display: "flex", alignItems: "center", gap: 8,
      padding: "6px 8px", borderRadius: 7,
      background: selected ? "rgba(31,194,152,0.12)" : "transparent",
      color: selected ? "var(--mint-800)" : "var(--fg-1)",
      fontSize: 13, fontWeight: selected ? 600 : 500,
    }}>
      <Icon name={icon || "shippingbox"} size={14} color={selected ? "var(--mint-600)" : "var(--fg-3)"}/>
      <span style={{ flex: 1, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{name}</span>
      <span style={{ fontFamily: APP_MONO_FONT, fontSize: 11, color: "var(--fg-3)" }}>{count}</span>
    </div>
  );
}

function RecentRow({ ep, alt }) {
  return (
    <div style={{
      display: "grid",
      gridTemplateColumns: "minmax(0,1.6fr) minmax(0,1.4fr) 100px 130px 60px",
      padding: "10px 16px",
      alignItems: "center",
      borderBottom: "0.5px solid var(--ink-100)",
      background: alt ? "rgba(236,251,245,0.35)" : "transparent",
      gap: 10,
    }}>
      <div style={{ display: "flex", alignItems: "center", gap: 10, minWidth: 0 }}>
        <Icon name="rectangle.stack.fill" size={16} color="var(--mint-600)"/>
        <div style={{ minWidth: 0 }}>
          <div style={{ fontWeight: 600, fontSize: 13, color: "var(--fg-1)", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{ep.name}</div>
          <div style={{ fontSize: 11, color: "var(--fg-3)" }}>· {ep.show}</div>
        </div>
      </div>
      <div style={{ fontFamily: APP_MONO_FONT, fontSize: 11, color: "var(--fg-3)", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{ep.path}</div>
      <div style={{ fontFamily: APP_MONO_FONT, fontSize: 11.5, color: "var(--fg-2)" }}>{ep.tracks}</div>
      <div style={{ fontSize: 12, color: "var(--fg-2)" }}>{ep.when}</div>
      <div style={{ display: "flex", justifyContent: "flex-end" }}>
        <Icon name="xmark.circle" size={14} color="var(--fg-4)"/>
      </div>
    </div>
  );
}

Object.assign(window, { HomeWarm, HomeWork, RECENTS });
