---
id: "0004"
title: "Local-first sync-ready schema + cloud activation plan"
status: open
labels: [wayfinder:ticket, wayfinder:research]
parent: "0001"
assignee: ""
blocked_by: ["0003"]
---

## Question

Design the persistence layer so v1 is 100% local-first, but the schema is engineered for a later cloud bolt-on without a rewrite.

Must specify:
- Database choice and schema rules: Room/SQLite (or equivalent), UUID primary keys on every row, created_at/updated_at timestamps, soft-delete tombstones.
- A "sync contract" — exactly which tables and fields would stream to a future backend, and which never will.
- **Pre-computed cloud activation plan**: cost model at 1k / 10k / 50k DAU, required backend components, and the concrete trigger condition (e.g., "self has used for 8 consecutive weeks and returns to it over Hevy").
- Backup story for v1: local export / Google Drive / iCloud file sync.

This replaces the earlier "cloud burn estimate" ticket. The cloud is not dead; it is a calculated phase-two with its costs and trigger written down in advance.
