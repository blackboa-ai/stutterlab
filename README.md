# StutterLab

**v0.1.0** · [Changelog](CHANGELOG.md)

A **read-only** Windows diagnostics tool that hunts the *causes* of gaming stutter:
frame-time spikes, micro-stalls, hitches, and the system-level contention that
produces them.

```
.\collect.ps1                  # 60s monitor + full report
.\collect.ps1 -Duration 180    # longer sampling window
.\collect.ps1 -NoMonitor       # static facts only, ~5 seconds
.\collect.ps1 -Open            # open the report when finished
```

Output lands in `runs\<timestamp>\`:

| File | Purpose |
|------|---------|
| `report.html` | Self-contained dashboard — double-click, works offline |
| `data.json` | Raw collected data, for diffing two runs |
| `collect.log` | Everything that happened, including what failed |

---

## What it does not do

It does **not** measure frame times. Real frame-time capture needs PresentMon
and ETW tracing.

What StutterLab does instead is measure **contention** — the system-side things
that steal time from the game's render thread and show up as spikes:

- DPC and interrupt time (driver overhead, often a controller/USB/audio driver)
- Disk latency and queue depth (asset streaming stalls)
- Memory pressure and page faults (8 GB machines fighting the page file)
- CPU frequency throttling (thermal or power-limit)
- GPU utilization and driver resets

Every finding names *why* it causes stutter, not just that it exists. Data dumps
make you interpret; this tells you what is wrong.

**It changes nothing.** No services stopped, no registry writes, no drivers
touched, no games modified. It reads, samples, and writes one HTML report.

---

## Requirements

- Windows 10 / 11
- PowerShell 5.1 (built in) — no installs, no modules, no internet
- **Administrator optional** but recommended. Without it, hardware inventory
  (CPU, RAM, disks, battery) is denied by Windows and those sections report as
  unavailable. Timer and event data still work.

---

## Layout

```
stutterlab/
├── collect.ps1            entry point — orchestration only
├── modules/
│   ├── Common.ps1         logging, safe-invoke wrapper, status tracking
│   ├── StaticFacts.ps1    one-shot hardware and configuration inventory
│   ├── Monitor.ps1        timed sampling session (the timeline)
│   ├── Events.ps1         event log correlation
│   ├── Rules.ps1          the rules engine — findings and severity
│   └── Render.ps1         data -> HTML
├── tools/
│   ├── check-balance.ps1  diagnostic: locate quoting/paren faults in a .ps1
│   └── rebuild-report.ps1 regenerate report.html from an existing data.json
├── docs/
│   └── SCOPE.md           what is measured, what is not, and why
└── runs/                  generated reports (git-ignored)
```

The rendered report has no template file of its own: `Render.ps1` builds the whole
document, stylesheet included, as strings. That keeps the output a single portable
HTML file with no CDN, no network access, and no external assets to go stale.

Each module is a set of functions and holds no state of its own. `collect.ps1`
wires them together. That split exists so a single collector can be fixed or
extended without touching anything else.

Because rules and rendering are pure functions over the captured data, a report
can be regenerated without touching the machine:

```powershell
.\tools\rebuild-report.ps1                    # newest run
.\tools\rebuild-report.ps1 -RunDir .\runs\2026-11-14_045455
```

Use it after editing a threshold or a chart. It reads `data.json` and rewrites
`report.html` beside it, and nothing else.

---

## Reading the report

Findings are ranked **critical → warn → info → ok**.

- **critical** — actively causing stutter, fix before tuning anything else
- **warn** — measurable overhead or a known risk factor
- **info** — worth knowing, not necessarily a problem
- **ok** — checked, came back clean

A clean report on a stuttering machine is itself useful information: it means
the cause is outside the system layer (thermal design, the game's own settings,
frame pacing, or a peripheral driver), and that is where the next step goes.

## Roadmap

- v0.2 — frame-time capture via PresentMon, overlay chart of frame times vs CPU/disk
- v0.3 — compare two runs (before/after a fix)
- v0.4 — live monitoring mode with a rolling window
