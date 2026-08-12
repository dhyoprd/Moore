# Issue Tracker: GitHub

This repo's issue tracker is **GitHub Issues** on `dhyoprd/Moore`.

## Wayfinding operations

- **Map** — a single issue labelled `wayfinder:map`. The canonical wayfinding map for the Moore spec is [issue #1: "Hevy Killer Spec — free, faster, smarter strength tracker"](https://github.com/dhyoprd/Moore/issues/1).
- **Tickets** — child issues labelled `wayfinder:ticket` + exactly one `wayfinder:<type>` label (`research`, `prototype`, `grilling`, `task`). A ticket links to its map in its body.
- **Blocking** — GitHub's API-native dependency graph isn't reliably available via `gh`; this repo therefore uses the **body convention**: a `Blocked by: #N` line in the ticket body. A ticket is **unblocked** when every issue it lists is closed. Keep this line in sync if dependencies change.
- **Frontier** — open issues labelled `wayfinder:ticket`, **unassigned**, whose `Blocked by:` lines all reference closed issues. Frontier query: `gh issue list --label wayfinder:ticket --state open --json number,title,assignees,body`.
- **Claim** — assign the issue to the dev driving the map (`gh issue edit N --add-assignee @me`) **before** any work. An open, unassigned ticket is unclaimed.
- **Resolution** — post the answer as a comment, `gh issue close N`, then append a one-line gist + link to the map's **Decisions so far**.

## Archive

The original local-markdown wayfinding files live in `issues/` (migrated to GitHub on 2026-07-30 as issues #1–#8, preserving numbering). They are kept as a historical archive; **GitHub Issues is canonical going forward** — do not edit the local copies to change state.
