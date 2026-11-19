---
status: accepted
date: 2026-11-18
decision-makers: gsuquet
---

# Record architecture decisions with MADR

## Context and Problem Statement

`infra` starts with a set of structural decisions settled before any platform code exists. The predecessor
repository `homelab` kept each decision inside long explanation pages, so the decision, its alternatives and its
date were hard to find. Where should `infra` keep its decisions, and in which format?

## Decision Drivers

* A reader (human or agent) finds a decision, its status and its reason in one file.
* A later decision can supersede an earlier one without rewriting history.
* Low ceremony: plain Markdown, reviewable in a pull request.

## Considered Options

* MADR files in `docs/adr/`
* Explanation pages, as in `homelab`
* Decisions in pull request descriptions only

## Decision Outcome

Chosen option: "MADR files in `docs/adr/`", because it gives one numbered, immutable file per decision with its
options and consequences, in a well-known format.

Files are named `NNNN-title-with-dashes.md`, numbered consecutively, and listed in [`README.md`](README.md).
An accepted ADR is not edited for substance: a new ADR supersedes it and both statuses are updated.

### Consequences

* Good, because each structural decision of the platform plan has one stable link.
* Good, because pull requests can cite the ADR they implement.
* Bad, because ADRs and README files can drift: READMEs describe the current state and link the ADR for the why.
* Number 0020 is reserved for the secrets backend decision, studied separately.

### Confirmation

Review: every structural change links an ADR or adds one. The index in `docs/adr/README.md` lists every file.

## Pros and Cons of the Options

### MADR files in `docs/adr/`

* Good, because the format is documented and stable (MADR 4.0.0).
* Good, because each file carries status, date and decision makers in front matter.
* Bad, because MADR suggests `docs/decisions/`; this repository uses the shorter, conventional `docs/adr/`.

### Explanation pages, as in `homelab`

* Good, because the reasoning reads as prose.
* Bad, because a decision is mixed with current-state description and has no status or date.

### Decisions in pull request descriptions only

* Good, because there is nothing extra to write.
* Bad, because the decision is not in the repository and is lost for agents working offline.

## More Information

* [MADR](https://adr.github.io/madr/)
