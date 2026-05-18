// app.jsx — mounts everything into the design canvas

const { useState, useEffect, useMemo } = React;

// Outer canvas — sections grouped by phase
function App() {
  return (
    <DesignCanvas>
      <DCSection
        id="intro"
        title="Maycast Studio — UI exploration"
        subtitle="Maycast-themed macOS Tahoe shell · realistic 3-track podcast episode · all major states"
      >
        <DCArtboard id="legend" label="Read me first" width={680} height={580}>
          <ReadmeCard/>
        </DCArtboard>
      </DCSection>

      <DCSection
        id="home"
        title="Home"
        subtitle="Warm welcome — hero waveform with recent episodes"
      >
        <DCArtboard id="home-warm" label="Home" width={1280} height={820}>
          <HomeWarm/>
        </DCArtboard>
      </DCSection>

      <DCSection
        id="episode"
        title="Episode workspace"
        subtitle="The shell once an Episode is open"
      >
        <DCArtboard id="ep-main" label="Episode view" width={1280} height={820}>
          <EpisodeView/>
        </DCArtboard>
      </DCSection>

      <DCSection
        id="slice"
        title="Slice editor"
        subtitle="The daily driver — per-track header strip on top, transcript bottom panel, gradient waveforms."
      >
        <DCArtboard id="slice-b" label="Slice editor" width={1400} height={880}>
          <SliceEditorB/>
        </DCArtboard>
      </DCSection>

      <DCSection
        id="polish"
        title="Polish sheet — every state"
        subtitle="The Auphonic round-trip, from key-not-set through completed and failed"
      >
        <DCArtboard id="polish-idle" label="Idle" width={760} height={820}>
          <PolishIdle/>
        </DCArtboard>
        <DCArtboard id="polish-key" label="Needs API key" width={760} height={820}>
          <PolishNeedsKey/>
        </DCArtboard>
        <DCArtboard id="polish-upload" label="Uploading" width={760} height={820}>
          <PolishUploading/>
        </DCArtboard>
        <DCArtboard id="polish-process" label="Processing" width={760} height={820}>
          <PolishProcessing/>
        </DCArtboard>
        <DCArtboard id="polish-done" label="Completed" width={760} height={820}>
          <PolishCompleted/>
        </DCArtboard>
        <DCArtboard id="polish-fail" label="Failed" width={760} height={820}>
          <PolishFailed/>
        </DCArtboard>
      </DCSection>

      <DCSection
        id="mix"
        title="Mix sheet — every state"
        subtitle="Combine tracks + Intro/Outro + ducking into a single broadcast file"
      >
        <DCArtboard id="mix-idle" label="Idle" width={760} height={840}>
          <MixIdle/>
        </DCArtboard>
        <DCArtboard id="mix-mix" label="Mixing" width={760} height={840}>
          <MixMixing/>
        </DCArtboard>
        <DCArtboard id="mix-done" label="Completed" width={760} height={840}>
          <MixCompleted/>
        </DCArtboard>
      </DCSection>

      <DCSection
        id="create"
        title="Creation sheets"
        subtitle="New Episode, New Show, and the Auphonic API key sheet"
      >
        <DCArtboard id="new-ep" label="New Episode" width={720} height={820}>
          <NewEpisodeSheet/>
        </DCArtboard>
        <DCArtboard id="new-show" label="New Show" width={720} height={780}>
          <NewShowSheet/>
        </DCArtboard>
        <DCArtboard id="auphonic" label="Auphonic API key" width={640} height={560}>
          <AuphonicSettingsSheet/>
        </DCArtboard>
      </DCSection>

      <DCSection
        id="history-error"
        title="History · Error"
        subtitle="Last-mile surfaces"
      >
        <DCArtboard id="history" label="Episode History" width={840} height={820}>
          <HistorySheet/>
        </DCArtboard>
        <DCArtboard id="error" label="Failed to open Episode" width={720} height={500}>
          <ErrorView/>
        </DCArtboard>
      </DCSection>
    </DesignCanvas>
  );
}

function ReadmeCard() {
  return (
    <div style={{
      width: "100%", height: "100%",
      padding: "40px 44px",
      background: "linear-gradient(180deg, #ecfbf5 0%, #eef9ff 100%)",
      color: "var(--fg-1)",
      fontFamily: APP_FONT,
      display: "flex", flexDirection: "column", gap: 18,
      overflow: "hidden",
      borderRadius: 8,
    }}>
      <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
        <LogoMark size={44}/>
        <div>
          <div style={{ fontFamily: APP_DISPLAY_FONT, fontWeight: 900, fontSize: 24, letterSpacing: "-0.01em" }}>Maycast Studio</div>
          <div style={{ fontSize: 12, color: "var(--fg-3)" }}>UI exploration · v0.1 · May 18 2026</div>
        </div>
      </div>
      <p style={{ margin: 0, fontSize: 14.5, lineHeight: 1.55, color: "var(--fg-2)", textWrap: "pretty" }}>
        Mocks of every screen described in the UI inventory. Visuals borrow Maycast’s brand
        (mint primary, sky accent, calm soft shadows) but the structure stays dense and pro-app — track headers,
        timecodes, multi-track waveforms, no extra chrome.
      </p>
      <div style={{ display: "flex", flexDirection: "column", gap: 10, marginTop: 4 }}>
        <ReadmeLine icon="rectangle.stack.fill" label="System">macOS Tahoe-style window chrome · translucent titlebar · 14px corner radius · soft drop shadow</ReadmeLine>
        <ReadmeLine icon="waveform" label="Hero">Slice editor — split / delete / transcript-aware with per-track header strips</ReadmeLine>
        <ReadmeLine icon="wand.and.sparkles" label="States">Polish & Mix sheets at every progress state from idle → done / failed</ReadmeLine>
        <ReadmeLine icon="text.quote" label="Content">code & coffee · ep12 “Rust rewrite” · host, guest, remote</ReadmeLine>
      </div>
      <div style={{ marginTop: "auto", fontSize: 11.5, color: "var(--fg-3)", lineHeight: 1.5 }}>
        Pan with two-finger / middle-drag · scroll-zoom to focus a card · click an artboard label to rename · ⌘-click an artboard to open it fullscreen.
      </div>
    </div>
  );
}

function ReadmeLine({ icon, label, children }) {
  return (
    <div style={{ display: "flex", alignItems: "flex-start", gap: 10 }}>
      <div style={{
        width: 24, height: 24, borderRadius: 7,
        background: "#fff", border: "0.5px solid var(--mint-200)",
        display: "flex", alignItems: "center", justifyContent: "center",
        flexShrink: 0, marginTop: 1,
      }}>
        <Icon name={icon} size={12} color="var(--mint-700)"/>
      </div>
      <div style={{ fontSize: 13, color: "var(--fg-2)" }}>
        <span style={{ fontWeight: 700, color: "var(--fg-1)", marginRight: 6 }}>{label}</span>
        {children}
      </div>
    </div>
  );
}

ReactDOM.createRoot(document.getElementById("root")).render(<App/>);
