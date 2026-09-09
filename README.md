# usage-bar

A macOS menu bar readout of Claude and GPT subscription usage, in one place.

```
C 69%  G 8%
```

Click it and the weekly numbers expand into Claude weekly / Fable / 5-hour, GPT weekly /
Spark weekly, and any remaining rate limit reset credits. Bars turn orange at 70% and red at 90%.

## Where the numbers come from

Two endpoints on the local [opencodex](https://www.npmjs.com/package/@bitkyc08/opencodex)
proxy (`127.0.0.1:10100`), authenticated with `~/.opencodex/admin-api-token`.

- `/api/provider-quotas` — Anthropic 5-hour, weekly, and Fable
- `/api/codex-auth/quota` — Codex weekly, Spark weekly, reset credits

No browser cookies, no keychain access, no outbound request of its own. If the proxy is not
running the app shows `?` rather than pretending the usage is zero.

This means the app is useless without opencodex. That is the point: existing menu bar meters
read Codex only, so the Claude side of an opencodex setup stays invisible.

## Polling

Every five minutes, plus an immediate read whenever the menu opens or you pick **Refresh now**.

Five minutes is not arbitrary. The proxy caches usage for exactly that long, so asking more
often returns the same answer, and the Claude reading costs the proxy a real request to
Anthropic each time it does refresh.

## Known limits

- Spark's 5-hour window is not exposed by the proxy. Only its weekly window is shown.
- The app is signed locally, so macOS labels it "from an unidentified developer". Removing
  that requires a paid Apple Developer certificate.

## Build and install

Requires macOS 14+ and the Swift toolchain that ships with Xcode command line tools. There is
no Xcode project; the build is one file.

```bash
./install.sh
```

That builds the app, copies it to `/Applications`, generates the launch agent from
`launchagent/*.plist.template` with the real path filled in, and loads it so the app starts at
login. `./build.sh` alone just produces `build/Usage Bar.app` if you would rather place it
yourself.

The `AssociatedBundleIdentifiers` key in the generated plist is what makes System Settings show
the app name and icon instead of the raw executable. Registering through `SMAppService` instead
does not work for a locally signed build; it fails with error 57.

To remove it:

```bash
launchctl unload -w ~/Library/LaunchAgents/com.minkyushim.usage-bar.plist
rm ~/Library/LaunchAgents/com.minkyushim.usage-bar.plist
rm -rf "/Applications/Usage Bar.app"
```

## Checking the values without the UI

```bash
"/Applications/Usage Bar.app/Contents/MacOS/Usage Bar" --dump
```

```
Claude
Weekly        ███████░░░  69%   09/10 04:59 (in 3h)
Fable         ██████████ 100%   09/10 04:59 (in 3h)
5-hour        █░░░░░░░░░   7%   09/10 05:49 (in 4h)
GPT
Weekly        ░░░░░░░░░░   0%   09/14 12:38 (in 4.4d)
Spark weekly  ░░░░░░░░░░   0%   09/17 02:14 (in 7.0d)
3 reset credits left
```

## Icon

`tools/make-icon.swift` regenerates `AppIcon.icns`. Change the colors or fill ratios there.

```bash
swift tools/make-icon.swift
sips -s format icns build/AppIcon.iconset/icon_512x512.png --out AppIcon.icns
```
