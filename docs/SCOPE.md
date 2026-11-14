# Scope

This document exists to keep the tool honest. It states what StutterLab measures,
what it deliberately does not, and the reasoning behind the thresholds in the
rules engine.

## The central limitation

Stutter is a property of **frame delivery over time**. A stutter is a frame that
arrives late — usually a single frame taking 40 ms instead of 8 ms, or a burst of
them. Measuring it properly requires hooking the graphics presentation pipeline:
PresentMon, or ETW providers such as `Microsoft-Windows-DxgKrnl`.

StutterLab does not do that in v0.1. It reads **system contention** instead: from
outside the game, what was competing for the CPU time, disk bandwidth, and memory
that the render thread needed.

This is a real limitation, and it has a specific consequence worth stating
plainly:

> A clean StutterLab report does **not** prove the system is innocent.
> It proves that the *layers we can see* were quiet during sampling.

Diagnosis therefore works by **elimination**, not by proof. Each rule that comes
back clean removes a candidate. When everything comes back clean, the remaining
candidates are the ones outside this tool's reach:

- the game's own frame pacing / shader compilation stalls
- thermal throttling under sustained load (sampled only if you run the tool *while* gaming)
- display-side issues (VRR, cable, refresh mismatch)
- peripheral driver DPC latency that only triggers under specific input
- network-side stutter in online games

## What is measured

### Static facts (one-shot)
Inventory of the machine as configured *right now*: CPU, RAM (capacity, per-stick
speed, channel population), GPU(s), driver versions, storage devices and health,
volumes, display mode and refresh rate, page file, power plan, and a set of
Windows gaming/perf switches (VBS, HVCI, HAGS, Game Mode, Game DVR).

Why static facts matter more than they look: several of the most common stutter
causes are *configuration* problems that never change at runtime — a single RAM
stick, XMP left off, the wrong power plan, a 60 Hz panel on a 165 Hz monitor.
These are invisible in any live graph.

### Monitor session (timed)
Samples once per second for a configurable duration:

| Signal | Counter | Why it relates to stutter |
|--------|---------|---------------------------|
| CPU total / per-core | `% Processor Time` | Saturation starves the render thread |
| DPC time | `% DPC Time` | Deferred procedure calls block *everything*, including the game |
| Interrupt time | `% Interrupt Time` | Hardware ISRs above ~2% indicate a bad driver |
| Privileged time | `% Privileged Time` | Kernel-mode work in the frame path |
| CPU frequency | `% of Maximum Frequency` | Below ~80% means thermal or power-limit throttling |
| Available memory | `Available MBytes` | Low headroom forces the page file into the frame path |
| Page faults | `Pages/sec` | Hard faults on the asset path cause hitches |
| Committed | `% Committed Bytes In Use` | Sustained >90% means the machine wants more RAM |
| Disk latency | `Avg. Disk sec/Transfer` | The single most common cause of streaming hitches |
| Disk queue | `Current Disk Queue Length` | Queue >2 is backlogged; >4 is a stall |
| Disk throughput | `Disk Bytes/sec` | Read context for the latency figure |
| GPU per-engine utilization | `GPU Engine(*)\Utilization Percentage` | Saturation, or a workload pinned to the iGPU |

Per-process CPU is computed as a delta of cumulative processor time across the
session, so it reports what actually consumed time while sampling rather than
lifetime totals.

### Event correlation
Windows records the failures that a live graph misses. Collected over 7 days:

- **Display driver resets** (`Display` 4101/4103) — a TDR is a visible freeze
- **Storage errors** (`Disk` 7/11/51/153, `storahci` 129) — retries stall I/O
- **Hardware errors** (`WHEA-Logger` 17/18/19/20/47) — corrected errors precede failures
- **Unexpected shutdowns** (`Kernel-Power` 41, `EventLog` 6008, `BugCheck` 1001)
- **Application crashes and hangs** (`Application Error` 1000, `Application Hang` 1002)

## Thresholds and their reasoning

These are judgement calls, documented so they can be argued with and tuned.

| Check | Threshold | Reasoning |
|-------|-----------|-----------|
| DPC time | >5% | Normally <1%. 5% is clearly abnormal and steals frame time directly. |
| Interrupt time | >2% | Same mechanism, lower absolute values before it hurts. |
| Disk latency | >25 ms sustained, >50 ms single spike | An SSD should be <1 ms. 25 ms is already a visible hitch. |
| Disk queue | >2 sustained | Requests are waiting; the outstanding work is not keeping up. |
| Available RAM | <1 GB | Below this Windows aggressively trims working sets mid-frame. |
| Committed | >90% | The system is out of room and paging is imminent. |
| CPU frequency | <80% of maximum | Indicates throttling rather than workload. |
| Free space | <10% | SSDs slow down and TRIM has nothing to work with. |
| Driver age | >365 days | Game-specific fixes almost always arrive in driver updates. |
| Single RAM stick | any | Single-channel roughly halves memory bandwidth; a known stutter source. |
| XMP off | configured < rated | RAM running below its rated speed. |

## Read-only guarantee

StutterLab makes no changes to the system. Specifically it does not:

- write to the registry, services, drivers, or power configuration
- stop, start, or modify any process or service
- install, update, or download anything
- require or open a network connection

It writes exactly two things: a run directory under `runs\`, and a log line per
step. Nothing else on the system is touched.
