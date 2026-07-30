---
id: "0008"
title: "iOS-first build & Android port plan"
status: open
labels: [wayfinder:ticket, wayfinder:task]
parent: "0001"
assignee: ""
blocked_by: ["0006"]
---

## Question

Define the execution plan: build iOS from the contract, then mechanically port to Android.

Must specify:
- Which contract sections are frozen before iOS starts.
- What "mechanical port" means: naming map, architecture mapping (SwiftUI → Compose, CoreData → Room), test parity.
- When Android starts (after iOS MVP feature-complete? after beta?).
- How contract changes are versioned so both platforms stay in sync.

Blocked by 0006 because without the contract template there is nothing to port against.
