# Release Process

How to cut a release of this distribution (`extension_drop`, name from
`META.json`'s top-level `name` field) and publish it to PGXN. Written to be
followed standalone, without other context.

## Overview

Releases use pgxntool's built-in `make tag`/`make dist` mechanics to produce a
`.zip`. There is currently **no CI automation for publishing** — the zip must
be uploaded to PGXN Manager by hand. See "Future: CI automation" below for the
planned upgrade path.

## Steps

1. Make sure `master` is in the state you want released, and CI is green.

2. Bump the version:
   - Edit `META.in.json`: bump the top-level `version` field AND the matching
     `version` under `provides.<extension>.version`. Do **not** touch
     `meta-spec.version` — that's the PGXN metadata spec version, always
     `1.0.0` regardless of your distribution's version.
   - Edit `<extension>.control`: bump `default_version` to match.
   - If maturity is changing, also update `release_status` in `META.in.json`
     (`unstable` -> `testing` -> `stable`).
   - Regenerate `META.json`: `rm -f META.json && make META.json`. It's a
     derived file — never hand-edit it directly (see `META.in.json` vs
     `META.json` in `pgxntool/CLAUDE.md`).

3. Add a changelog entry in `HISTORY.asc` at the repo root (this project's
   own file — not `pgxntool/HISTORY.asc`, which documents pgxntool itself).
   Format: a line with the version number, a line of dashes matching its
   length, then one or more `== <heading>` blocks with a short prose blurb
   each. Newest version goes at the top. Follow the existing entries in this
   file for the exact style.

4. Commit the version bump + changelog together in one commit. Message
   convention used by this project: `"<version>: <one-line summary>"` (e.g.
   `"1.0.0: Add PostgreSQL 9.3-17 support, promote to stable"`).

5. Make sure your `origin` git remote points at the canonical upstream repo
   (`Postgres-Extensions/extension_tools`, not a personal fork) —
   `make tag` pushes to whatever `origin` is, and a tag pushed to a fork does
   nothing for PGXN.

6. Run `make dist`. This:
   - Refuses to run with uncommitted changes.
   - Creates (or verifies) a git tag matching `PGXNVERSION` — the bare version
     number, e.g. `1.0.0`, no `v` prefix, matching this project's convention
     (check `meta.mk` if unsure what `PGXNVERSION` resolved to) — and pushes
     it to `origin`.
   - Runs `git archive` at that tag into `../<dist-name>-<version>.zip` (e.g.
     `../extension_drop-1.0.0.zip`).
   - If you need to redo a release before anyone's downloaded it:
     `make forcedist` (deletes + recreates the tag, rebuilds the zip). Don't
     do this once the version has been public for a while — moving a
     published tag out from under people is disruptive.

7. Upload the zip at https://manager.pgxn.org/ (log in, use the release form).
   You need a registered PGXN Manager account with rights to this
   distribution.

8. Verify the new version shows up at `https://pgxn.org/dist/<name>/` (can
   take a few minutes to index).

## Future: CI automation

Right now this is entirely manual. The `pgtap` extension (a sibling project,
not part of this org) has a `.github/workflows/release.yml` that
auto-publishes to PGXN on tag push, using the `pgxn/pgxn-tools` Docker image
(`pgxn-bundle` + `pgxn-release` steps), and auto-creates a GitHub release from
the changelog. Adopting the same pattern here would remove steps 6-7 above,
but requires storing PGXN Manager credentials as a GitHub Actions secret —
deliberately deferred for this release.

## Notes / gotchas discovered while writing this

- pgxntool's own `make tag`/`make dist` create a *real* git tag, despite
  `pgxntool/README.asc` describing the result as a "branch" — that's stale
  wording in the docs, not current behavior.
- There's no automated check that `META.in.json`'s top-level version, its
  `provides.<extension>.version`, and `<extension>.control`'s
  `default_version` all agree — verify all three by hand before tagging.
- `META.in.json`'s `resources` block (homepage/bugtracker/repository URLs)
  should point at the actual current repo home. It had drifted to a stale
  `decibel/extension_drop` URL (GitHub redirects it via repo-transfer, but
  that shouldn't be relied on) until fixed as part of the 1.0.0 release prep.
