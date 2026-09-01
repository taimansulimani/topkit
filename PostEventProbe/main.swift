import CoreGraphics

// Standalone live probe for the auto-paste PostEvent (⌘V) TCC permission. This tiny tool is
// embedded in Topkit.app (Contents/MacOS/postevent-probe) and sublaunched by
// PermissionManager.probePostEventAccessLive().
//
// Why a separate process: running fresh, it reads the LIVE TCC state. Inside the long-running
// app, CGPreflightPostEventAccess() caches its result for the rest of the session — Apple DTS:
// "does not update while my process is running" — so it reads stale-false after a grant and can
// read stale-true after a revoke. A brand-new process has no such cache.
//
// Why this is App Store / sandbox legal: it is signed with EXACTLY two entitlements,
// com.apple.security.app-sandbox and com.apple.security.inherit, so when Topkit sublaunches it
// the tool inherits Topkit's sandbox. This is Apple's documented "Embedding a command-line tool
// in a sandboxed app" pattern. (Consequently it can only be run by the app, never from Terminal,
// because outside the app there is no sandbox to inherit.)
//
// Contract: no output, no UI, exit code is the answer — 0 = granted, 1 = denied.
exit(CGPreflightPostEventAccess() ? 0 : 1)
