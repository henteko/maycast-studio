// sheets-polish.jsx — Polish sheet at idle / uploading / processing / completed / failed

const POLISH_DEFAULTS = {
  loudness: -16,
  leveler: true,
  denoise: true,
  denoiseMethod: "Dynamic",
  filler: true,
  silence: true,
  cough: false,
  debreath: "6",
  highpass: true,
  keepOnAuphonic: false,
};

function PolishHeader({ apiKey = "configured" }) {
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 12 }}>
      <div style={{ display: "flex", alignItems: "flex-start", gap: 12 }}>
        <div style={{
          width: 38, height: 38, borderRadius: 10,
          background: "linear-gradient(180deg, var(--mint-100), var(--mint-200))",
          display: "flex", alignItems: "center", justifyContent: "center",
        }}>
          <Icon name="wand.and.sparkles" size={18} color="var(--mint-700)"/>
        </div>
        <div style={{ flex: 1 }}>
          <div style={{ display: "flex", alignItems: "baseline", gap: 8 }}>
            <span style={{ fontFamily: APP_DISPLAY_FONT, fontWeight: 700, fontSize: 19 }}>Polish</span>
            <span style={{ fontSize: 12, color: "var(--fg-3)" }}>via Auphonic</span>
          </div>
          <p style={{ margin: "4px 0 0", fontSize: 12.5, color: "var(--fg-2)", lineHeight: 1.5 }}>
            Cleans each track through the Auphonic Multitrack API — noise reduction, silence cuts, leveling, and loudness normalization. The polished files land in <code style={{ fontFamily: APP_MONO_FONT, fontSize: 11.5, padding: "1px 4px", background: "var(--ink-100)", borderRadius: 4 }}>intermediate/&lt;track&gt;/</code>.
          </p>
        </div>
        <Chip tone="neutral" icon={<Icon name="rectangle.stack" size={11}/>}>{TRACKS.length} tracks</Chip>
      </div>

      <ApiKeyRow state={apiKey}/>
    </div>
  );
}

function ApiKeyRow({ state }) {
  const ok = state === "configured";
  return (
    <div style={{
      display: "flex", alignItems: "center", gap: 10,
      padding: "10px 14px",
      background: ok ? "var(--success-bg)" : "var(--warning-bg)",
      border: `0.5px solid ${ok ? "var(--mint-200)" : "rgba(245,158,11,0.3)"}`,
      borderRadius: 10,
    }}>
      <Icon name={ok ? "key.fill" : "key.slash"} size={15} color={ok ? "var(--mint-600)" : "#c4760a"}/>
      <div style={{ flex: 1, fontSize: 12.5 }}>
        <span style={{ fontWeight: 600, color: ok ? "var(--mint-800)" : "#7a4a06" }}>Auphonic API key</span>
        <span style={{ marginLeft: 8, color: "var(--fg-3)" }}>
          {ok ? <>configured · <span style={{ fontFamily: APP_MONO_FONT }}>••••2f1a</span></> : "not set"}
        </span>
      </div>
      <Btn kind="ghost" size="sm">{ok ? "Change…" : "Configure…"}</Btn>
    </div>
  );
}

function PolishTracksList({ progress = null, faded = false }) {
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
      {TRACKS.map((t, i) => {
        const pct = progress ? progress[t.id] ?? 0 : null;
        return (
          <div key={t.id} style={{
            padding: "10px 14px",
            background: "var(--bg-1)",
            border: "0.5px solid var(--border-1)",
            borderRadius: 10,
            display: "flex", flexDirection: "column", gap: 6,
            opacity: faded ? 0.6 : 1,
          }}>
            <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
              <div style={{ width: 28, height: 28, borderRadius: 7, background: "var(--mint-50)", border: "0.5px solid var(--mint-200)", display: "flex", alignItems: "center", justifyContent: "center" }}>
                <Icon name="waveform" size={13} color="var(--mint-600)"/>
              </div>
              <span style={{ fontFamily: APP_MONO_FONT, fontWeight: 700, fontSize: 12.5 }}>{t.id}</span>
              <span style={{ fontFamily: APP_MONO_FONT, fontSize: 11, color: "var(--fg-3)", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{t.source}</span>
              <div style={{ flex: 1 }}/>
              <span style={{ fontFamily: APP_MONO_FONT, fontSize: 11.5, color: "var(--fg-2)" }}>{t.dur}</span>
            </div>
            {pct !== null && (
              <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                <Progress value={pct} color="var(--mint-500)" style={{ flex: 1 }}/>
                <span style={{ fontFamily: APP_MONO_FONT, fontSize: 10.5, color: "var(--fg-3)", minWidth: 36, textAlign: "right" }}>{pct}%</span>
              </div>
            )}
          </div>
        );
      })}
    </div>
  );
}

function EffectsCard() {
  return (
    <div style={{
      padding: "14px 16px",
      background: "var(--bg-1)",
      border: "0.5px solid var(--border-1)",
      borderRadius: 12,
      display: "flex", flexDirection: "column", gap: 14,
    }}>
      <SectionLabel>Effects</SectionLabel>

      <EffectRow icon="speaker.wave.2" label="Loudness target">
        <div style={{ display: "flex", alignItems: "center", gap: 10, flex: 1 }}>
          <Slider value={0.7}/>
          <span style={{ fontFamily: APP_MONO_FONT, fontSize: 12, color: "var(--fg-1)", fontWeight: 600, minWidth: 70, textAlign: "right" }}>−16.0 LUFS</span>
        </div>
      </EffectRow>

      <EffectRow icon="slider.horizontal.3" label="Adaptive Leveler">
        <Toggle on/>
      </EffectRow>

      <EffectRow icon="wand.and.sparkles" label="Denoise">
        <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
          <PickerChip>Dynamic</PickerChip>
          <Toggle on/>
        </div>
      </EffectRow>

      <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
        <div style={{ display: "flex", alignItems: "center", gap: 8, color: "var(--fg-2)", fontSize: 12.5, fontWeight: 600 }}>
          <Icon name="scissors" size={13} color="var(--sky-600)"/> Cuts
        </div>
        <div style={{ display: "flex", flexDirection: "column", paddingLeft: 22, gap: 6 }}>
          <SubToggle label="Filler word cutter" on/>
          <SubToggle label="Silence cutter" on/>
          <SubToggle label="Cough cutter"/>
        </div>
      </div>

      <EffectRow icon="waveform.path" label="Debreath amount">
        <PickerChip>6 dB</PickerChip>
      </EffectRow>

      <EffectRow icon="waveform.path" label="High-pass filter">
        <Toggle on/>
      </EffectRow>

      <EffectRow icon="tray.full" label="Keep production on Auphonic dashboard">
        <Toggle/>
      </EffectRow>
    </div>
  );
}

function SectionLabel({ children }) {
  return <div style={{ fontSize: 10.5, fontWeight: 700, color: "var(--fg-3)", textTransform: "uppercase", letterSpacing: "0.08em" }}>{children}</div>;
}

function EffectRow({ icon, label, children }) {
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
      <div style={{ flex: "0 0 240px", display: "flex", alignItems: "center", gap: 8 }}>
        <Icon name={icon} size={14} color="var(--fg-2)"/>
        <span style={{ fontSize: 12.5, color: "var(--fg-1)", fontWeight: 500 }}>{label}</span>
      </div>
      <div style={{ flex: 1, display: "flex", justifyContent: "flex-end" }}>{children}</div>
    </div>
  );
}

function SubToggle({ label, on }) {
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
      <Toggle on={on} small/>
      <span style={{ fontSize: 12.5, color: "var(--fg-1)" }}>{label}</span>
    </div>
  );
}

function Toggle({ on, small }) {
  const w = small ? 30 : 36, h = small ? 18 : 20, knob = small ? 14 : 16;
  return (
    <div style={{
      width: w, height: h, borderRadius: 999,
      background: on ? "var(--mint-500)" : "var(--ink-200)",
      position: "relative", transition: "all 160ms var(--ease-out)",
      boxShadow: on ? "inset 0 0 0 0.5px rgba(15,96,78,0.3)" : "inset 0 0 0 0.5px rgba(14,31,26,0.1)",
    }}>
      <div style={{
        position: "absolute", top: 2, left: on ? w - knob - 2 : 2,
        width: knob, height: knob, borderRadius: "50%",
        background: "#fff", boxShadow: "0 1px 3px rgba(14,31,26,0.2), 0 0 0 0.5px rgba(14,31,26,0.05)",
        transition: "left 160ms var(--ease-out)",
      }}/>
    </div>
  );
}

function Slider({ value = 0.5 }) {
  return (
    <div style={{ flex: 1, height: 4, background: "var(--ink-100)", borderRadius: 999, position: "relative" }}>
      <div style={{ position: "absolute", left: 0, top: 0, height: "100%", width: `${value * 100}%`, background: "var(--mint-400)", borderRadius: 999 }}/>
      <div style={{ position: "absolute", left: `calc(${value * 100}% - 7px)`, top: -5, width: 14, height: 14, borderRadius: "50%", background: "#fff", border: "0.5px solid var(--border-2)", boxShadow: "var(--shadow-xs)" }}/>
    </div>
  );
}

function PickerChip({ children }) {
  return (
    <div style={{
      padding: "4px 8px 4px 10px",
      background: "#fff",
      border: "0.5px solid var(--border-2)",
      borderRadius: 7,
      display: "inline-flex", alignItems: "center", gap: 6,
      fontSize: 12, fontWeight: 600,
    }}>
      {children}
      <Icon name="chevron.down" size={11} color="var(--fg-3)"/>
    </div>
  );
}

// Status row
function StatusRow({ tone, icon, text, sub }) {
  const palette = {
    idle:     { bg: "var(--bg-2)",       fg: "var(--fg-2)",     bd: "var(--border-1)" },
    info:     { bg: "var(--sky-50)",     fg: "var(--sky-700)",  bd: "var(--sky-200)" },
    progress: { bg: "var(--mint-50)",    fg: "var(--mint-700)", bd: "var(--mint-200)" },
    success:  { bg: "var(--success-bg)", fg: "var(--mint-700)", bd: "var(--mint-200)" },
    warning:  { bg: "var(--warning-bg)", fg: "#c4760a",         bd: "rgba(245,158,11,0.3)" },
    danger:   { bg: "var(--danger-bg)",  fg: "var(--danger)",   bd: "rgba(239,68,68,0.25)" },
  }[tone] || {};
  return (
    <div style={{
      padding: "10px 14px",
      background: palette.bg,
      border: `0.5px solid ${palette.bd}`,
      borderRadius: 10,
      display: "flex", alignItems: "center", gap: 10,
    }}>
      {icon}
      <div style={{ flex: 1 }}>
        <div style={{ fontSize: 12.5, fontWeight: 600, color: palette.fg }}>{text}</div>
        {sub && <div style={{ fontSize: 11.5, color: "var(--fg-3)", marginTop: 2, fontFamily: APP_MONO_FONT }}>{sub}</div>}
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// Variants
// ─────────────────────────────────────────────────────────────

function PolishCommon({ subtitle, status, footer, faded, progress, apiKey }) {
  return (
    <SheetFrame
      width={680}
      minHeight={700}
      title="Polish"
      subtitle={subtitle}
      rightHeader={<Btn kind="ghost" size="sm" icon={<Icon name="xmark" size={13}/>}/>}
      footer={footer}
    >
      <div style={{ display: "flex", flexDirection: "column", gap: 14 }}>
        <PolishHeader apiKey={apiKey}/>

        <div>
          <SectionLabel>Speakers</SectionLabel>
          <div style={{ height: 8 }}/>
          <PolishTracksList progress={progress} faded={faded}/>
        </div>

        <EffectsCard/>

        {status}
      </div>
    </SheetFrame>
  );
}

function PolishIdle() {
  return (
    <PolishCommon
      subtitle="Send these tracks to Auphonic for cleanup. Original sources stay untouched — each track gains a new generation."
      status={<StatusRow tone="idle" icon={<Icon name="circle.dashed" size={15} color="var(--fg-3)"/>} text="Ready"/>}
      footer={
        <>
          <div style={{ flex: 1 }}/>
          <Btn kind="primary" glow icon={<Icon name="arrow.up.circle" size={14} color="#fff"/>}>Send to Auphonic</Btn>
        </>
      }
    />
  );
}

function PolishNeedsKey() {
  return (
    <PolishCommon
      subtitle="Send these tracks to Auphonic for cleanup."
      apiKey="missing"
      status={<StatusRow tone="warning" icon={<Icon name="exclamationmark.triangle" size={15} color="#c4760a"/>} text="Set an Auphonic API key to continue."/>}
      footer={
        <>
          <div style={{ flex: 1 }}/>
          <Btn kind="primary" disabled icon={<Icon name="arrow.up.circle" size={14} color="#fff"/>}>Send to Auphonic</Btn>
        </>
      }
    />
  );
}

function PolishUploading() {
  return (
    <PolishCommon
      subtitle="Uploading audio. Don’t close the window until all tracks have arrived on Auphonic."
      progress={{ host: 100, guest: 72, remote: 18 }}
      status={
        <StatusRow
          tone="info"
          icon={<Icon name="spinner" size={16} color="var(--sky-600)"/>}
          text="Uploading to Auphonic…"
          sub="2 of 3 in flight · 152 MB sent / 217 MB"
        />
      }
      footer={
        <>
          <Btn kind="secondary">Cancel</Btn>
          <div style={{ flex: 1 }}/>
          <Btn kind="primary" disabled>Uploading…</Btn>
        </>
      }
    />
  );
}

function PolishProcessing() {
  return (
    <PolishCommon
      subtitle="Auphonic is running your tracks through its audio algorithms."
      status={
        <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
          <StatusRow
            tone="progress"
            icon={<Icon name="spinner" size={16} color="var(--mint-600)"/>}
            text="Auphonic processing — Audio Algorithms"
            sub="Stage 3 of 5 · Loudness normalization · ~ 1 min remaining"
          />
          <div style={{
            padding: "10px 14px",
            background: "var(--bg-2)",
            border: "0.5px solid var(--border-1)",
            borderRadius: 10,
            fontFamily: APP_MONO_FONT, fontSize: 11.5, color: "var(--fg-3)",
            display: "flex", flexDirection: "column", gap: 4,
          }}>
            <div>✓ Upload complete</div>
            <div>✓ Voice activity detection</div>
            <div>✓ Denoising</div>
            <div style={{ color: "var(--mint-700)", fontWeight: 600 }}>→ Loudness normalization (in progress)</div>
            <div>· Cut detection (filler / silence)</div>
            <div>· Final mastering</div>
          </div>
        </div>
      }
      footer={
        <>
          <Btn kind="secondary">Cancel</Btn>
          <div style={{ flex: 1 }}/>
          <Btn kind="primary" disabled>Processing…</Btn>
        </>
      }
    />
  );
}

function PolishCompleted() {
  return (
    <PolishCommon
      subtitle="All three tracks were polished. They’ve been written into the bundle as new generations."
      progress={{ host: 100, guest: 100, remote: 100 }}
      status={
        <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
          <StatusRow
            tone="success"
            icon={<Icon name="checkmark.seal.fill" size={16} color="var(--mint-600)"/>}
            text="Polish complete (3 tracks)"
            sub="11.4s round-trip · 3 new generations"
          />
          <div style={{
            padding: "10px 14px",
            background: "var(--bg-2)",
            border: "0.5px solid var(--border-1)",
            borderRadius: 10,
            display: "flex", flexDirection: "column", gap: 6,
          }}>
            {TRACKS.map((t, i) => (
              <div key={t.id} style={{ display: "flex", alignItems: "center", gap: 8, fontFamily: APP_MONO_FONT, fontSize: 11 }}>
                <span style={{ fontWeight: 700, color: "var(--fg-1)", width: 50 }}>{t.id}</span>
                <span style={{ color: "var(--fg-3)" }}>→</span>
                <span style={{ color: "var(--mint-700)" }}>intermediate/{t.id}/00{t.gens + 1}_polish.wav</span>
              </div>
            ))}
          </div>
        </div>
      }
      footer={
        <>
          <div style={{ flex: 1 }}/>
          <Btn kind="secondary">Close</Btn>
          <Btn kind="primary" icon={<Icon name="arrow.uturn.forward" size={13} color="#fff"/>}>Back to Episode</Btn>
        </>
      }
    />
  );
}

function PolishFailed() {
  return (
    <PolishCommon
      subtitle="Send these tracks to Auphonic for cleanup."
      progress={{ host: 100, guest: 100, remote: 42 }}
      status={
        <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
          <StatusRow
            tone="danger"
            icon={<Icon name="exclamationmark.triangle.fill" size={16} color="var(--danger)"/>}
            text="Polish failed on track “remote”"
            sub="Auphonic returned 503 (service unavailable) after retry 3/3"
          />
          <div style={{
            padding: "10px 14px",
            background: "var(--danger-bg)",
            border: "0.5px solid rgba(239,68,68,0.25)",
            borderRadius: 10,
            fontFamily: APP_MONO_FONT, fontSize: 11, color: "#9a2424",
            whiteSpace: "pre-wrap",
            lineHeight: 1.5,
          }}>
{`POST https://auphonic.com/api/productions.json/8f3a/start
↳ 503 Service Unavailable
{"error": "queue full, try again", "queue_position": null}`}
          </div>
        </div>
      }
      footer={
        <>
          <Btn kind="secondary">Close</Btn>
          <div style={{ flex: 1 }}/>
          <Btn kind="primary" icon={<Icon name="arrow.uturn.backward" size={13} color="#fff"/>}>Retry</Btn>
        </>
      }
    />
  );
}

Object.assign(window, {
  PolishIdle, PolishNeedsKey, PolishUploading, PolishProcessing, PolishCompleted, PolishFailed,
});
