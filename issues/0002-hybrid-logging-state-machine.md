---
id: "0002"
title: "Hybrid logging state machine — exact tap flow with planned default"
status: open
labels: [wayfinder:ticket, wayfinder:grilling]
parent: "0001"
assignee: ""
blocked_by: []
---

## Question

Define the exact finite-state machine for a hybrid logging flow where each set has a planned default (from last session or program) and the user can (a) accept in 1 tap, (b) edit then accept, (c) mark failed, (d) mark dropset/superset.

Must specify:
- States: planned, active, rest, completed, failed, dropped.
- Transitions and UI affordances per state.
- How many taps for the 80% case (planned → completed).
- How the 20% edits are surfaced without modal overload.

This is the single biggest "faster than Hevy" lever. Resolve in one grilling session.
