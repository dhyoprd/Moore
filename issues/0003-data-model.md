---
id: "0003"
title: "Data model — Exercise, Set, Routine, Template, Folder, PR, Analytics"
status: open
labels: [wayfinder:ticket, wayfinder:grilling]
parent: "0001"
assignee: ""
blocked_by: ["0002"]
---

## Question

Define the platform-agnostic domain model and its invariants.

Must specify:
- Entities: Exercise, PlannedSet, CompletedSet, WorkoutSession, Routine, Template, Folder, PersonalRecord, BodyMetric.
- Relationships and cardinality.
- Immutable fields vs. mutable snapshots.
- How a "1-tap accept" maps a PlannedSet → CompletedSet without data loss.
- PR calculation rules (1RM estimate, volume, rep PR).
- Migration/versioning strategy for the contract.

Blocked by 0002 because the logging state machine determines which set types must exist.
