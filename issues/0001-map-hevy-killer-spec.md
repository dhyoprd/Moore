---
id: "0001"
title: "Hevy Killer Spec — free, faster, smarter strength tracker"
status: open
labels: [wayfinder:map]
---

## Destination

A buildable spec for a free, no-paywall strength tracker that beats Hevy at its core: unlimited routines, folders, plate calculator, analytics, no ads, faster hybrid logging, and smart progression guidance. **Validation gate: the spec is successful when the builder uses it to replace Hevy on their own phone for 8 consecutive weeks.** Marketing and gym partnerships are deferred until after this gate passes. The spec is written as a platform-agnostic contract so it can be mechanically translated to native Swift (iOS) and Kotlin (Android) by a solo dev + AI agents.

## Notes

- Domain: gym / strength training / progression analytics.
- Build: solo developer + AI agents (iOS-first, Android port from the same contract).
- Architecture principle: **spec is the contract** — all behavior, data models, state machines, and math must be written platform-agnostically in this map's tickets, never inside Swift/Kotlin code.
- **Persistence: local-first (on-device DB) with sync-ready schema** (UUIDs, timestamps, tombstones). Cloud is a pre-computed phase two, activated only after the self-validation gate passes.
- Standing preferences: keep it stupidly simple; no speculative features; no paywall, ever.
- Skills to consult: `/grilling`, `/domain-modeling`, `/research`, `/prototype`.

## Decisions so far

<!-- index only; detail lives in the closed ticket -->

## Not yet specified

- Multi-language / localization strategy (assumes English-first).
- Import path from Hevy (CSV export) to reduce switching friction — valuable for the builder's own migration.
- Release cadence / TestFlight strategy for personal device installation.
- Self-validation metrics: how to measure whether the builder actually uses it over Hevy (streak, logging speed vs Hevy, retention of the app on phone).
- When the self-validation gate passes: exact trigger and steps to activate cloud + begin marketing.

## Out of scope

- Connect-to-gym features (equipment catalog, busy-ness, gym-branded programs, door access) — deferred to a future effort; requires a two-sided marketplace.
- Marketing strategy and gym partnership plans — deferred until after the self-validation gate (8 weeks of personal use) passes.
- Cloud backend implementation — deferred until the trigger in ticket 0004 fires. The *planning* of cloud costs and activation is in scope (see ticket 0004); the *building* of it is not.
- Making a profit / monetization — all features are free.
