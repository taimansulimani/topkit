★ PRIOR 2.4.5 REJECTION → APPROVED ★
Topkit was rejected under Guideline 2.4.5 for optional clipboard auto-paste, then approved after Resolution Center. This build keeps that same approved behaviour. Please read this (and Resolution Center) before rejecting on 2.4.5 again.

What happened: Review treated PostEvent (shown under “Accessibility” in System Settings) as misuse of the Accessibility API. That was incorrect for this app.

What we clarified — still true:
- We do NOT call AXIsProcessTrusted, any AXUIElement API, or kTCCServiceAccessibility. We never inspect or control other apps’ UI (sandboxed).
- Auto-paste uses CGEvent.post via PostEvent (kTCCServicePostEvent). Apple DTS: PostEvent is sandbox-compatible and distinct from Accessibility. It only appears under that System Settings pane; it is not the AX API.
- Only when the user explicitly selects a clipboard-history item: copy + one synthetic ⌘V to the previously frontmost app. Default OFF; never background.
- Purpose: I built Topkit for myself, I have a left-thumb ligament injury; ⌘ chords are painful. Same benefit for RSI / limited motor control. Not claiming Topkit is solely assistive tech.

Precedent (live MAS):
- WhisperPad 6755522991 — App Review Board reversed 2.4.5 (June 2026); “pastes the text straight into your focused field.”
- Maccy 1527619437 — select + paste; Accessibility (“Paste automatically”).
- Paste 967805235 — paste history into other apps.

Topkit is narrower: default-off, single ⌘V, only after explicit menu selection. Already approved once for this app; mechanism unchanged.

---

Topkit: macOS menu bar productivity app (LSUIElement). The listing groups it as three jobs: copy and paste, present and annotate, and record annotated screenshots and videos. In the menu bar that is: clipboard history with search, Screenshot, Record Screen, Pick Color, Magnify, Halo, and Annotate (freehand, shapes, arrows, text, stickers, redact, numbered badges, measure, guides, grid). No account/analytics/ads/backend/IAPs. Local only. No test credentials.

THIS BINARY (vs first approved build)
- Record: screen recording + optional on-device dictation subtitles + optional mic audio
- Present and annotate: live Annotate (freehand, shapes, arrows, text, stickers, redact, numbered badges). Guides, grid and measure are now tools inside Annotate, not separate menu items.
- Copy and paste: clipboard search, pinning, image hover previews
- Auto-paste unchanged (PostEvent / ⌘V; default OFF)

PERMISSIONS (only when used)
1. Screen Recording — picker, magnify, screenshot/annotate, recording.
2. Microphone — optional subtitles and/or mic track (off by default).
3. Speech Recognition — legacy SFSpeech path only; always on-device; no Apple-server fallback; we have no servers.
4. PostEvent — only if user enables “Input ⌘V after menu item selection”.
5. Network — none. No com.apple.security.network.client or .server entitlement in the sandbox. Verifiable from the binary.

HOW TO TEST
1. Menu bar → clipboard; with auto-paste ON (Preferences → Clipboard), select item → one ⌘V.
2. Screenshot / Annotate / Pick Color / Magnify / Record → Screen Recording on first use.
3. Record → optional Dictate subtitles / Record microphone → mic (and speech if prompted). Tray red while recording.
4. Annotate ▸ Vertical Guide / Horizontal Guide / Grid, and the global shortcuts, work without Screen Recording.
