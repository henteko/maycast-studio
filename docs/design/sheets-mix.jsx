// sheets-mix.jsx — Mix sheet at idle / mixing / completed

function MixHeader() {
  return (
    <div style={{ display: "flex", alignItems: "flex-start", gap: 12 }}>
      <div style={{
        width: 38, height: 38, borderRadius: 10,
        background: "linear-gradient(180deg, var(--sun-100), #ffd994)",
        display: "flex", alignItems: "center", justifyContent: "center",
      }}>
        <Icon name="square.stack.3d.down.forward" size={18} color="#a17220"/>
      </div>
      <div style={{ flex: 1 }}>
        <div style={{ display: "flex", alignItems: "baseline", gap: 8 }}>
          <span style={{ fontFamily: APP_DISPLAY_FONT, fontWeight: 700, fontSize: 19 }}>Mix</span>
          <span style={{ fontSize: 12, color: "var(--fg-3)" }}>final export</span>
        </div>
        <p style={{ margin: "4px 0 0", fontSize: 12.5, color: "var(--fg-2)", lineHeight: 1.5 }}>
          Combines every polished track with the Show’s Intro / Outro and writes a single broadcast-ready file.
        </p>
      </div>
      <Chip tone="neutral" icon={<Icon name="rectangle.stack" size={11}/>}>3 tracks</Chip>
    </div>
  );
}

function MixTracksList() {
  return (
    <div style={{
      padding: "12px 14px",
      background: "var(--bg-1)",
      border: "0.5px solid var(--border-1)",
      borderRadius: 12,
      display: "flex", flexDirection: "column", gap: 8,
    }}>
      {TRACKS.map((t) => (
        <div key={t.id} style={{ display: "flex", alignItems: "center", gap: 10, padding: "2px 0" }}>
          <Icon name="waveform" size={14} color="var(--mint-600)"/>
          <span style={{ fontFamily: APP_MONO_FONT, fontWeight: 700, fontSize: 12 }}>{t.id}</span>
          <span style={{ fontFamily: APP_MONO_FONT, fontSize: 11, color: "var(--fg-3)", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{t.current}</span>
          <div style={{ flex: 1 }}/>
          <span style={{ fontFamily: APP_MONO_FONT, fontSize: 11.5, color: "var(--fg-2)" }}>{t.dur}</span>
        </div>
      ))}
      <div style={{
        marginTop: 4,
        paddingTop: 10,
        borderTop: "0.5px solid var(--border-1)",
        display: "flex", justifyContent: "space-between",
        fontSize: 12,
      }}>
        <div style={{ display: "flex", gap: 18 }}>
          <div>
            <div style={{ fontSize: 10.5, color: "var(--fg-3)", textTransform: "uppercase", letterSpacing: "0.06em", fontWeight: 700 }}>Output duration</div>
            <div style={{ fontFamily: APP_MONO_FONT, fontWeight: 600, color: "var(--fg-1)" }}>38:51.61</div>
          </div>
          <div>
            <div style={{ fontSize: 10.5, color: "var(--fg-3)", textTransform: "uppercase", letterSpacing: "0.06em", fontWeight: 700 }}>Output format</div>
            <div style={{ fontFamily: APP_MONO_FONT, color: "var(--fg-1)" }}>16-bit PCM WAV · stereo</div>
          </div>
        </div>
      </div>
    </div>
  );
}

function IntroOutroCard() {
  return (
    <div style={{
      padding: "14px 16px",
      background: "var(--bg-1)",
      border: "0.5px solid var(--border-1)",
      borderRadius: 12,
      display: "flex", flexDirection: "column", gap: 12,
    }}>
      <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
        <Icon name="music.note" size={14} color="var(--fg-2)"/>
        <span style={{ fontSize: 12.5, fontWeight: 700, color: "var(--fg-1)" }}>Intro / Outro overlap</span>
      </div>

      <AssetRow label="Intro" path="show/intro_v3.wav" dur="8.5s"/>
      <AssetRow label="Outro" path="show/outro_loop_v2.wav" dur="6.0s"/>

      <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 12, paddingTop: 4 }}>
        <SliderRow label="Intro overlap" value={0.42} display="3.5 s"/>
        <SliderRow label="Outro overlap" value={0.65} display="3.9 s"/>
        <SliderRow label="Ducking gain"  value={0.36} display="−9 dB"/>
        <SliderRow label="Ducking fade"  value={0.50} display="1.0 s"/>
      </div>

      <div style={{
        marginTop: 6, paddingTop: 12,
        borderTop: "0.5px dashed var(--border-1)",
        display: "flex", alignItems: "center", gap: 10,
      }}>
        <Btn kind="secondary" size="sm" icon={<Icon name="play.circle" size={14} color="var(--mint-600)"/>}>Preview intro transition</Btn>
        <Btn kind="secondary" size="sm" icon={<Icon name="play.circle" size={14} color="var(--mint-600)"/>}>Preview outro transition</Btn>
      </div>
    </div>
  );
}

function AssetRow({ label, path, dur }) {
  return (
    <div style={{
      padding: "8px 10px",
      background: "var(--bg-2)",
      borderRadius: 8,
      display: "flex", alignItems: "center", gap: 10,
    }}>
      <Icon name="checkmark.seal.fill" size={14} color="var(--mint-600)"/>
      <span style={{ fontSize: 12, fontWeight: 600, width: 38 }}>{label}</span>
      <span style={{ fontFamily: APP_MONO_FONT, fontSize: 11, color: "var(--fg-3)", flex: 1, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{path}</span>
      <span style={{ fontFamily: APP_MONO_FONT, fontSize: 11, color: "var(--fg-2)" }}>{dur}</span>
    </div>
  );
}

function SliderRow({ label, value, display }) {
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
      <div style={{ display: "flex", justifyContent: "space-between", fontSize: 11.5 }}>
        <span style={{ color: "var(--fg-2)" }}>{label}</span>
        <span style={{ fontFamily: APP_MONO_FONT, fontWeight: 600, color: "var(--fg-1)" }}>{display}</span>
      </div>
      <div style={{ height: 4, background: "var(--ink-100)", borderRadius: 999, position: "relative" }}>
        <div style={{ position: "absolute", left: 0, top: 0, height: "100%", width: `${value * 100}%`, background: "var(--mint-400)", borderRadius: 999 }}/>
        <div style={{ position: "absolute", left: `calc(${value * 100}% - 6px)`, top: -4, width: 12, height: 12, borderRadius: "50%", background: "#fff", border: "0.5px solid var(--border-2)", boxShadow: "var(--shadow-xs)" }}/>
      </div>
    </div>
  );
}

function OutputPathRow({ path = "exports/ep12-rust-rewrite.wav" }) {
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
      <SectionLabel>Output path</SectionLabel>
      <div style={{
        display: "flex", alignItems: "center", gap: 8,
        padding: "0 10px",
        background: "var(--bg-1)",
        border: "0.5px solid var(--border-2)",
        borderRadius: 9,
        height: 34,
      }}>
        <Icon name="folder" size={14} color="var(--fg-3)"/>
        <span style={{ fontFamily: APP_MONO_FONT, fontSize: 12, color: "var(--fg-1)", flex: 1 }}>{path}</span>
        <Btn kind="ghost" size="sm">Choose…</Btn>
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
function MixIdle() {
  return (
    <SheetFrame width={680} minHeight={720} title="Mix" subtitle="Stitch everything into a single broadcast file" rightHeader={<Btn kind="ghost" size="sm" icon={<Icon name="xmark" size={13}/>}/>}
      footer={
        <>
          <div style={{ flex: 1 }}/>
          <Btn kind="primary" glow icon={<Icon name="square.stack.3d.down.forward" size={14} color="#fff"/>}>Mix</Btn>
        </>
      }
    >
      <div style={{ display: "flex", flexDirection: "column", gap: 14 }}>
        <MixHeader/>
        <MixTracksList/>
        <IntroOutroCard/>
        <OutputPathRow/>
        <StatusRow tone="idle" icon={<Icon name="circle.dashed" size={15} color="var(--fg-3)"/>} text="Ready to mix"/>
      </div>
    </SheetFrame>
  );
}

function MixMixing() {
  return (
    <SheetFrame width={680} minHeight={720} title="Mix" subtitle="Mixing in progress…" rightHeader={<Btn kind="ghost" size="sm" icon={<Icon name="xmark" size={13}/>}/>}
      footer={
        <>
          <Btn kind="secondary">Cancel</Btn>
          <div style={{ flex: 1 }}/>
          <Btn kind="primary" disabled>Mixing…</Btn>
        </>
      }
    >
      <div style={{ display: "flex", flexDirection: "column", gap: 14 }}>
        <MixHeader/>
        <MixTracksList/>
        <IntroOutroCard/>
        <OutputPathRow/>
        <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
          <StatusRow
            tone="progress"
            icon={<Icon name="spinner" size={16} color="var(--mint-600)"/>}
            text="Mixing…"
            sub="Rendering · 24.1s of 38:51 · 1.6× realtime"
          />
          <Progress value={62} height={8}/>
        </div>
      </div>
    </SheetFrame>
  );
}

function MixCompleted() {
  return (
    <SheetFrame width={680} minHeight={720} title="Mix" subtitle="Mix complete" rightHeader={<Btn kind="ghost" size="sm" icon={<Icon name="xmark" size={13}/>}/>}
      footer={
        <>
          <Btn kind="secondary" icon={<Icon name="folder" size={13}/>}>Reveal in Finder</Btn>
          <div style={{ flex: 1 }}/>
          <Btn kind="primary" icon={<Icon name="arrow.uturn.backward" size={13} color="#fff"/>}>Mix again</Btn>
        </>
      }
    >
      <div style={{ display: "flex", flexDirection: "column", gap: 14 }}>
        <MixHeader/>
        <MixTracksList/>
        <IntroOutroCard/>
        <OutputPathRow/>

        <div style={{
          padding: "18px 18px",
          background: "linear-gradient(135deg, var(--mint-50) 0%, #f6fffb 100%)",
          border: "0.5px solid var(--mint-200)",
          borderRadius: 14,
          display: "flex", alignItems: "center", gap: 14,
        }}>
          <div style={{
            width: 44, height: 44, borderRadius: 12,
            background: "linear-gradient(180deg, var(--mint-400), var(--mint-500))",
            display: "flex", alignItems: "center", justifyContent: "center",
            boxShadow: "var(--shadow-mint)",
          }}>
            <Icon name="checkmark.seal.fill" size={22} color="#fff"/>
          </div>
          <div style={{ flex: 1 }}>
            <div style={{ fontFamily: APP_DISPLAY_FONT, fontWeight: 700, fontSize: 16, color: "var(--mint-800)" }}>Mix complete</div>
            <div style={{ fontSize: 12, color: "var(--mint-700)", marginTop: 2 }}>Written in 23.4s · ready for upload</div>
          </div>
          <div style={{ textAlign: "right" }}>
            <div style={{ fontFamily: APP_MONO_FONT, fontSize: 12, color: "var(--mint-700)" }}>exports/ep12-rust-rewrite.wav</div>
            <div style={{ fontFamily: APP_MONO_FONT, fontSize: 11, color: "var(--mint-600)" }}>38:51.61 · 412.4 MB</div>
          </div>
        </div>
      </div>
    </SheetFrame>
  );
}

Object.assign(window, { MixIdle, MixMixing, MixCompleted });
