# Issue Tracker: Local Markdown

This repo has no external issue tracker. Wayfinding uses the **local-markdown tracker**.

## Where things live
- **Issues & maps**: `issues/` directory. Each issue is one markdown file.
- **Naming**: `NNNN-slug.md`, e.g., `0001-map-hevy-killer-spec.md`.
- **Labels**: in frontmatter, e.g., `labels: [wayfinder:map]` or `labels: [wayfinder:ticket, wayfinder:research]`.
- **Blocking**: no native tracker blocking → **body convention**. In a ticket file, a `Blocked by:` section lists issue file paths. A ticket is unblocked when every listed issue is closed.
- **Closed**: frontmatter `status: closed` plus a `## Resolution` section at the bottom.
- **Claimed**: frontmatter `assignee: <dev/session-id>`. Open + unassigned = unclaimed.
- **Children of a map**: tickets reference their map via `parent: NNNN`.

## File layout
- Map: `issues/NNNN-map-<slug>.md` with label `wayfinder:map`.
- Ticket: `issues/NNNN-<slug>.md` with labels `wayfinder:ticket, wayfinder:<type>`.
