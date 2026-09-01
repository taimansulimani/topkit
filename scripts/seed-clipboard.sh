#!/usr/bin/env bash
# Seeds the macOS clipboard with a mix of sophisticated code snippets,
# advanced product-designer-to-AI prompts, hex colour codes, and real
# annotated screenshots of demo apps, so Topkit's clipboard history fills
# up with realistic-looking content for marketing screenshots/video. Dev
# tooling only — not part of the app or any build.
#
# The images in seed-assets/ are real screenshots of unrelated demo apps
# (Waveform, Ledger, Pulse, Orbit — used only as believable clipboard
# filler) captured and annotated with Topkit's own annotate toolbar, then
# exported as PNGs so this script doesn't depend on those apps being open.
#
# Requires Topkit to already be running (it polls the pasteboard every 0.5s,
# see Topkit/ClipboardManager.swift).
#
# Order matters: items copied LAST end up at the TOP of the history, so the
# entries below are written bottom-of-menu-first, top-of-menu-last. Same
# shape as before: a couple of images + a couple of hex swatches sit in the
# top 10, the rest of the images/colours land below that.

set -euo pipefail

ASSETS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/seed-assets"

DELAY=1.0   # > 0.5s poll interval, gives each copy its own history entry

copy_text() {
  printf '%s' "$1" | pbcopy
  sleep "$DELAY"
}

copy_image() {
  osascript -e "set the clipboard to (read (POSIX file \"$1\") as «class PNGf»)"
  sleep "$DELAY"
}

# ---------------------------------------------------------------------------
# --- these end up BELOW position 10 ---
# ---------------------------------------------------------------------------

copy_text "export const tokens = {
  surfaceSunken: '#0F1B1E',
  hairline: 'rgba(255,255,255,0.08)',
  accentAlt: '#5EEAD4',
} as const;

type Token = keyof typeof tokens;"

copy_text "Run the annotate toolbar through VoiceOver's rotor order and fix anything that reads before the canvas it labels - right now the sticker picker announces before the image it's stickering"

copy_image "$ASSETS_DIR/pulse-regression.png"

copy_text "SELECT
  item_id,
  created_at,
  LAG(created_at) OVER (PARTITION BY item_id ORDER BY created_at) AS prev_copy,
  created_at - LAG(created_at) OVER (PARTITION BY item_id ORDER BY created_at) AS gap
FROM clipboard_items
WHERE pinned = 0
QUALIFY gap < INTERVAL '2 seconds';"

copy_text "Rebuild the seek drag as a controlled gesture that springs back to the committed position on release instead of trusting onChange mid-drag - a fast flick currently overshoots and reports the wrong ratio"

copy_text "rg -n 'BAR_HEIGHT|ART_RADIUS' src/ --type tsx"

copy_text "Confirm the pink came from the wrong token, not a one-off hex, then add an eslint rule that flags raw hex literals under theme/ so this can't land unreviewed again"

copy_image "$ASSETS_DIR/orbit-deploywindow.png"

# ---------------------------------------------------------------------------
# --- these are the TOP 10, in reverse (last one below = very top) ---
# ---------------------------------------------------------------------------

copy_text "231 and 232 look different in the player bar but I cannot pin it down. Where did it change?"

copy_text "#e879f9"

copy_text "const onSeek = useCallback(
  (ratio: number) => seek(ratio * track.duration),
  [seek, track.duration],
);"

copy_text "Compare every commit between the two tags and call out the ones touching theme or spacing files specifically, skip anything under tests/"

copy_image "$ASSETS_DIR/waveform-coverart.png"

copy_text "private let seekSubject = PassthroughSubject<Double, Never>()

seekSubject
    .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
    .removeDuplicates()
    .sink { [weak self] ratio in
        self?.player.seek(to: ratio * duration)
    }
    .store(in: &cancellables)"

copy_text "#e0559e"

copy_text "Check whether the new spacing tokens shipped with a default of zero anywhere, that would explain rows collapsing without anything actually throwing"

copy_image "$ASSETS_DIR/ledger-negativebalance.png"

copy_text "Add a layout snapshot test so this can't ship silently again - pin it to the transport row baseline Mira called out in the design review"

echo "Seed complete: 18 entries — top 10 has 2 annotated screenshots + 2 hex swatches, other 2 screenshots sit below."
