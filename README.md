# usage-bar

A macOS menu bar readout of Claude and GPT subscription usage, in one place.

```
C 69%  G 8%
```

Click it and the weekly numbers expand into Claude weekly / Fable / 5-hour / extra usage /
reset grants, and GPT weekly / credit balance / reset credits. Bars turn orange at 70% and red
at 90%.

## Where the numbers come from

Mostly from the local [opencodex](https://www.npmjs.com/package/@bitkyc08/opencodex)
proxy (`127.0.0.1:10100`), authenticated with `~/.opencodex/admin-api-token`.

- `/api/provider-quotas` — Anthropic 5-hour, weekly, and Fable
- `/api/codex-auth/quota` — Codex weekly and reset credits
- `/api/anthropic/reset-grants` — Claude usage-limit reset grants
- `/api/codex-auth/reset-credits?accountId=__main__` — GPT reset credits with expiry dates
- `/api/request-history?limit=1` — only to notice that a request just finished

Two balances the proxy reads but does not expose are fetched directly:

- Claude extra usage: `api.anthropic.com/api/oauth/usage`, with the proxy's current
  Anthropic access token from `~/.opencodex/auth.json`
- GPT credit balance: `chatgpt.com/backend-api/wham/usage`, with the Codex token from
  `~/.codex/auth.json` (or `$CODEX_HOME`)

Those tokens are only read. If one has expired the app skips that value and keeps the last
one; it never refreshes a token, because a refresh would rotate it out from under the proxy.
No browser cookies, no keychain access. If the proxy is not running the app shows `?` rather
than pretending the usage is zero.

This means the app is useless without opencodex. That is the point: existing menu bar meters
read Codex only, so the Claude side of an opencodex setup stays invisible.

## Polling

Three speeds:

- Every minute, a plain read from the proxy. This is free: it returns the proxy's cache, and
  GPT numbers in that cache already update in-band with every Codex response.
- Every ten seconds, the newest entry in the proxy's request log. When a new request has
  finished, the app reads again at once and asks the proxy to re-probe upstream
  (`?refresh=1`), at most once a minute. That re-probe is what moves the Claude numbers, and it
  costs a real request to Anthropic, hence the limit.
- Every ten minutes, the credit balances and reset grants, which rarely change.

Opening the menu reads the proxy again (and the balances, if the last read is over a minute
old). **Refresh now** forces everything.

Usage spent outside the proxy (claude.ai in a browser, for example) does not appear in the
request log, so it shows up on the proxy's own five-minute cycle instead.

## Known limits

- The Claude and GPT balances depend on undocumented upstream fields (`extra_usage`,
  `credits`). If either disappears, its row simply stops showing.
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

System Settings lists a launch agent under the name and icon of its executable, not of the app
bundle around it. The `AssociatedBundleIdentifiers` key would link the two, but only for apps
signed with a developer certificate. So `install.sh` gives the executable a custom icon
(`tools/set-file-icon.swift`); without it the item shows as a generic "exec" tile. The icon
lives in extended attributes, so the code signature stays valid. Registering through
`SMAppService` instead does not work for a locally signed build; it fails with error 57.

Install only this way. If the app also ends up under "Open at Login", both copies start at
login; the second one notices the first and quits, so the menu bar still shows one item.

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
Extra usage   $0.00 / $15.00 this month
Resets        1 left · expires 10/23
GPT
Weekly        ░░░░░░░░░░   0%   09/14 12:38 (in 4.4d)
Credits       0 credits
Resets        3 left · next expires 10/30
```

## Icon

`tools/make-icon.swift` regenerates `AppIcon.icns`. Change the colors or fill ratios there.

```bash
swift tools/make-icon.swift
sips -s format icns build/AppIcon.iconset/icon_512x512.png --out AppIcon.icns
```
