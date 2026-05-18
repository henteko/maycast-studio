// sheets-create.jsx — NewEpisode, NewShow, AuphonicSettings sheets

function PathField({ value, placeholder, withChoose = true }) {
  return (
    <div style={{
      display: "flex", alignItems: "center", gap: 8,
      padding: "0 4px 0 10px",
      height: 34,
      background: "var(--bg-1)",
      border: "0.5px solid var(--border-2)",
      borderRadius: 9,
    }}>
      <Icon name="folder" size={13} color="var(--fg-3)"/>
      <span style={{
        flex: 1, minWidth: 0,
        fontFamily: APP_MONO_FONT, fontSize: 12,
        color: value ? "var(--fg-1)" : "var(--fg-4)",
        overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap",
      }}>{value || placeholder}</span>
      {withChoose && <Btn kind="ghost" size="sm">Choose…</Btn>}
    </div>
  );
}

function TextField({ value, placeholder, width, mono = false, style }) {
  return (
    <div style={{
      display: "flex", alignItems: "center",
      padding: "0 10px",
      height: 30,
      background: "var(--bg-1)",
      border: "0.5px solid var(--border-2)",
      borderRadius: 8,
      width,
      ...style,
    }}>
      <span style={{
        fontSize: mono ? 12 : 13,
        color: value ? "var(--fg-1)" : "var(--fg-4)",
        fontFamily: mono ? APP_MONO_FONT : APP_FONT,
        overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap",
      }}>{value || placeholder}</span>
    </div>
  );
}

function FormField({ label, hint, children, icon }) {
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
      <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
        {icon && <Icon name={icon} size={14} color="var(--fg-2)"/>}
        <span style={{ fontSize: 12.5, fontWeight: 600, color: "var(--fg-1)" }}>{label}</span>
        {hint && <span style={{ fontSize: 11, color: "var(--fg-3)", fontWeight: 500 }}>{hint}</span>}
      </div>
      {children}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
function NewEpisodeSheet() {
  return (
    <SheetFrame
      width={640}
      minHeight={720}
      title="New Episode"
      subtitle="Bundle a fresh episode. Pick a show and add speaker tracks — audio files are copied into the bundle so the originals stay untouched."
      rightHeader={<Btn kind="ghost" size="sm" icon={<Icon name="xmark" size={13}/>}/>}
      footer={
        <>
          <Btn kind="secondary">Cancel</Btn>
          <div style={{ flex: 1 }}/>
          <Btn kind="primary" glow icon={<Icon name="plus.rectangle" size={14} color="#fff"/>}>
            Create
            <KeyHint mod label="↩"/>
          </Btn>
        </>
      }
    >
      <div style={{ display: "flex", flexDirection: "column", gap: 18 }}>
        <FormField label="Bundle path" icon="folder.badge.plus" hint="Episode ID: derived from filename">
          <div style={{ display: "flex", gap: 8 }}>
            <PathField value="~/Podcasts/Code & Coffee/ep13-async-rust.maycast" withChoose={false}/>
            <Btn kind="secondary" size="sm">Choose…</Btn>
          </div>
        </FormField>

        <FormField label="Show" icon="shippingbox" hint="optional">
          <div style={{
            padding: "10px 12px",
            background: "var(--mint-50)",
            border: "0.5px solid var(--mint-200)",
            borderRadius: 10,
            display: "flex", alignItems: "center", gap: 10,
          }}>
            <Icon name="checkmark.seal.fill" size={15} color="var(--mint-600)"/>
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ fontSize: 13, fontWeight: 600 }}>code & coffee</div>
              <div style={{ fontFamily: APP_MONO_FONT, fontSize: 11, color: "var(--fg-3)" }}>~/Shows/code-and-coffee.maycastshow</div>
            </div>
            <Btn kind="ghost" size="sm">Change…</Btn>
            <Btn kind="ghost" size="sm" destructive>Remove</Btn>
          </div>
        </FormField>

        <FormField label="Speakers" icon="person.2.wave.2" hint="optional">
          <div style={{
            border: "0.5px solid var(--border-1)",
            borderRadius: 10,
            background: "var(--bg-2)",
            padding: 10,
            display: "flex", flexDirection: "column", gap: 6,
          }}>
            <SpeakerRow trackId="host"   file="zoom_recording_host.wav"   ok/>
            <SpeakerRow trackId="guest"  file="zoom_recording_guest.wav"  ok/>
            <SpeakerRow trackId="remote" file=""                          />
            <div style={{ display: "flex", alignItems: "center", gap: 8, padding: "4px 0 0" }}>
              <Btn kind="ghost" size="sm" icon={<Icon name="plus" size={12}/>}>Add</Btn>
              <span style={{ fontSize: 11, color: "var(--fg-3)" }}>Each speaker becomes a track in the new Episode. Audio files are copied into <code style={{ fontFamily: APP_MONO_FONT, fontSize: 10.5, background: "#fff", padding: "1px 4px", borderRadius: 4 }}>sources/</code>.</span>
            </div>
          </div>
        </FormField>

        <StatusRow tone="idle" icon={<Icon name="circle.dashed" size={15} color="var(--fg-3)"/>} text="Ready to create"/>
      </div>
    </SheetFrame>
  );
}

function SpeakerRow({ trackId, file, ok, error }) {
  return (
    <div style={{
      display: "flex", alignItems: "center", gap: 8,
      padding: "6px 8px",
      background: "#fff",
      border: error ? "0.5px solid rgba(239,68,68,0.4)" : "0.5px solid var(--border-1)",
      borderRadius: 8,
    }}>
      <TextField value={trackId} width={110} mono/>
      <Icon name={ok ? "waveform" : "circle.dashed"} size={14} color={ok ? "var(--mint-600)" : "var(--fg-3)"}/>
      <span style={{
        flex: 1, fontFamily: APP_MONO_FONT, fontSize: 12,
        color: file ? "var(--fg-1)" : "var(--fg-4)",
        overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap",
      }}>{file || "Choose an audio file…"}</span>
      <Btn kind="ghost" size="sm">{file ? "Change…" : "Choose…"}</Btn>
      <div style={{
        width: 22, height: 22, borderRadius: 6,
        display: "flex", alignItems: "center", justifyContent: "center",
        color: "var(--fg-3)",
      }}>
        <Icon name="xmark" size={12}/>
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
function NewShowSheet() {
  return (
    <SheetFrame
      width={640}
      minHeight={680}
      title="New Show"
      subtitle="Create a show bundle. Intro / Outro assets are snapshot-copied into each Episode created from this show, so future edits never affect past episodes."
      rightHeader={<Btn kind="ghost" size="sm" icon={<Icon name="xmark" size={13}/>}/>}
      footer={
        <>
          <Btn kind="secondary">Cancel</Btn>
          <div style={{ flex: 1 }}/>
          <Btn kind="primary" glow icon={<Icon name="shippingbox" size={14} color="#fff"/>}>
            Create
          </Btn>
        </>
      }
    >
      <div style={{ display: "flex", flexDirection: "column", gap: 18 }}>
        <FormField label="Bundle path" icon="folder.badge.plus">
          <div style={{ display: "flex", gap: 8 }}>
            <PathField value="~/Shows/morning-pages.maycastshow" withChoose={false}/>
            <Btn kind="secondary" size="sm">Choose…</Btn>
          </div>
        </FormField>

        <FormField label="Display name">
          <TextField value="Morning Pages" placeholder="Falls back to the bundle filename"/>
        </FormField>

        <FormField label="Assets" icon="music.note.list" hint="optional">
          <div style={{
            border: "0.5px solid var(--border-1)",
            borderRadius: 10,
            background: "var(--bg-2)",
            padding: 12,
            display: "flex", flexDirection: "column", gap: 8,
          }}>
            <AssetSelectorRow label="Intro" file="intro_loop_v3.wav"/>
            <AssetSelectorRow label="Outro" file=""/>
            <div style={{ fontSize: 11, color: "var(--fg-3)" }}>Selected files are copied into the bundle.</div>
          </div>
        </FormField>

        <StatusRow tone="idle" icon={<Icon name="circle.dashed" size={15} color="var(--fg-3)"/>} text="Ready to create"/>
      </div>
    </SheetFrame>
  );
}

function AssetSelectorRow({ label, file }) {
  const ok = !!file;
  return (
    <div style={{
      display: "flex", alignItems: "center", gap: 10,
      padding: "8px 10px",
      background: "#fff",
      border: "0.5px solid var(--border-1)",
      borderRadius: 8,
    }}>
      <Icon name={ok ? "checkmark.seal.fill" : "circle.dashed"} size={15} color={ok ? "var(--mint-600)" : "var(--fg-3)"}/>
      <span style={{ width: 48, fontWeight: 600, fontSize: 12.5 }}>{label}</span>
      <span style={{ flex: 1, fontFamily: APP_MONO_FONT, fontSize: 11.5, color: file ? "var(--fg-2)" : "var(--fg-4)", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{file || "Choose an audio file…"}</span>
      <Btn kind="ghost" size="sm">{ok ? "Change…" : "Choose…"}</Btn>
      {ok && <Icon name="xmark" size={12} color="var(--fg-3)"/>}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
function AuphonicSettingsSheet() {
  return (
    <SheetFrame
      width={560}
      minHeight={460}
      title="Auphonic API key"
      subtitle={<>Issue a key from <a style={{ color: "var(--mint-700)", fontWeight: 600 }}>auphonic.com/engine/account</a>. The key is stored in your macOS Keychain and never leaves this machine.</>}
      rightHeader={<Btn kind="ghost" size="sm" icon={<Icon name="xmark" size={13}/>}/>}
      footer={
        <>
          <Btn kind="destructive">Remove</Btn>
          <div style={{ flex: 1 }}/>
          <Btn kind="secondary">Cancel</Btn>
          <Btn kind="primary" glow>Replace</Btn>
        </>
      }
    >
      <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>
        <div style={{
          padding: "12px 14px",
          background: "var(--success-bg)",
          border: "0.5px solid var(--mint-200)",
          borderRadius: 10,
          display: "flex", alignItems: "center", gap: 10,
        }}>
          <Icon name="key.fill" size={16} color="var(--mint-600)"/>
          <div style={{ flex: 1 }}>
            <div style={{ fontSize: 13, fontWeight: 600, color: "var(--mint-800)" }}>An API key is currently set</div>
            <div style={{ fontSize: 11.5, color: "var(--fg-3)", marginTop: 2 }}>Stored in Keychain — last used 2 minutes ago</div>
          </div>
          <span style={{ fontFamily: APP_MONO_FONT, fontSize: 12, color: "var(--mint-700)" }}>••••2f1a</span>
        </div>

        <FormField label="New API key" hint="paste a fresh key to replace the one above">
          <div style={{
            display: "flex", alignItems: "center", gap: 6,
            padding: "0 10px",
            height: 36,
            background: "var(--bg-1)",
            border: "0.5px solid var(--border-2)",
            borderRadius: 9,
          }}>
            <span style={{ fontFamily: APP_MONO_FONT, fontSize: 13, color: "var(--fg-4)", letterSpacing: "0.1em" }}>•••••••••••••••••</span>
          </div>
        </FormField>

        <div style={{
          padding: "10px 14px",
          background: "var(--bg-2)",
          border: "0.5px solid var(--border-1)",
          borderRadius: 10,
          fontSize: 12, color: "var(--fg-2)", lineHeight: 1.55,
          display: "flex", gap: 10, alignItems: "flex-start",
        }}>
          <Icon name="info.circle" size={14} color="var(--fg-3)" style={{ flexShrink: 0, marginTop: 1 }}/>
          <span>
            Maycast Studio never stores your key in plaintext — it lives in the macOS Keychain and is fetched only when sending a Polish job. Read more about how Polish works in the docs.
          </span>
        </div>
      </div>
    </SheetFrame>
  );
}

Object.assign(window, { NewEpisodeSheet, NewShowSheet, AuphonicSettingsSheet });
