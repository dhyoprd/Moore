---
id: "0005"
title: "Smart progression rules — what 'smarter than Hevy' means in code"
status: open
labels: [wayfinder:ticket, wayfinder:grilling]
parent: "0001"
assignee: ""
blocked_by: ["0003"]
---

## Question

Define the exact progression and coaching logic the app will suggest.

Must specify:
- Stall detection rules (e.g., 3 sessions at same weight with reps < target).
- Progression schemes: linear, double progression, percentage-based.
- Deload rules.
- "What should I lift today" auto-suggestion algorithm.
- How suggestions appear in UI (inline hint vs. banner vs. none).

Must be rules-based, not ML, for v1. Resolve in one grilling session.
