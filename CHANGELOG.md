# Changelog

All notable changes to StutterLab are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The version is declared in `collect.ps1` (`$tool.version`) and printed in the
footer of every generated report.

## [Unreleased]

Planned for v0.2.0 and later; see Roadmap in `README.md`.

## [0.1.0] - 2026-11-14

First working release. Read-only: it samples and reports, and changes nothing.

### Added

- **Entry point** `collect.ps1` with `-Duration`, `-NoMonitor`, `-Open` and
  `-OutDir` parameters.
- **Static fact collection** — CPU, RAM, disks, battery, GPU (via
  `nvidia-smi` when present), Windows build, power plan and relevant
  configuration toggles.
- **Timed contention monitor** sampling DPC and interrupt time, disk latency
  and queue depth, memory pressure and page faults, CPU frequency throttling,
  GPU utilization and driver resets.
- **Event log correlation** for hardware errors, display driver resets and
  unexpected shutdowns occurring during the sampling window.
- **Rules engine** ranking findings critical, warn, info or ok, with each
  finding naming why it causes stutter rather than only reporting a value.
- **Self-contained HTML report** built entirely in `Render.ps1` — no template,
  no CDN, no network access, works offline by double-clicking.
- **Structured output** per run under `runs\<timestamp>\`: `report.html`,
  `data.json` and `collect.log`.
- **`tools/rebuild-report.ps1`** to regenerate a report from an existing
  `data.json` without touching the machine.
- **`tools/check-balance.ps1`** to locate quoting and parenthesis faults in a
  PowerShell script.
- **`docs/SCOPE.md`** documenting what is measured and what is deliberately
  not.

### Notes

- Requires PowerShell 5.1, built into Windows 10 and 11. No modules, no
  installs, no internet.
- Administrator is optional. Without elevation, hardware inventory is denied by
  Windows and those sections report as unavailable; timer and event collection
  still work.

### Known limitations

- Does not capture frame times. That requires PresentMon and ETW tracing and is
  scoped for v0.2.0.

Version history is also recorded as annotated git tags (`v0.1.0` and onward),
so `git tag -n` lists every release with its summary.
