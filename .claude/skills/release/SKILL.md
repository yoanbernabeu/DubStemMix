---
name: release
description: Publish a new DubStemMix version. Proposes the next version number, bumps it everywhere it is written by hand (landing page, README), drafts the release notes in the usual style, and after the user's OK commits, pushes, publishes the GitHub release (which builds and attaches the zip) and checks the result. Use when the user asks to release, publish a version, ship 0.x.0, or runs /release [version].
---

# Release DubStemMix

Answer the user in French. Nothing leaves the machine (commit, push, tag, release) before the user's explicit OK at step 5.

## How a version works here

- The app's version is **not in the code**. It comes from the git tag: publishing the GitHub release `vX.Y.Z` runs `.github/workflows/release.yml`, which tests, builds with `tools/make-app.sh X.Y.Z` and uploads `DubStemMix-X.Y.Z.zip` to the release. The in-app updater looks for exactly that zip name.
- Written by hand, and forgotten without this skill:
  - `web/src/site.ts` → `version: "X.Y.Z"` (badge and download name on the landing page). The page is redeployed by `.github/workflows/pages.yml` on any push to main touching `web/`.
  - `README.md` → the example `tools/make-app.sh X.Y.Z dist` in "Build from source".
- The Homebrew cask (`yoanbernabeu/homebrew-tap`, `Casks/dubstemmix.rb`) is bumped by `release.yml` itself (deploy key `HOMEBREW_TAP_DEPLOY_KEY`): nothing to do by hand, just check the tap got a "DubStemMix X.Y.Z" commit.
- Release title: `DubStemMix X.Y.Z`. Tag: `vX.Y.Z`, on main.

## Steps

### 1. Check the ground

Stop and tell the user if any of these fails:

- on `main`, working tree clean, up to date with `origin/main` (`git fetch` then compare);
- `swift test` passes;
- the CI run of the current HEAD is green: `gh run list --branch main --workflow CI --limit 1`.

### 2. Choose the number

- Last version: `git describe --tags --abbrev=0`.
- If the user gave a number (`/release 0.9.1`), use it. Otherwise propose the next minor: `0.9.0 → 0.10.0` (numbers, not alphabetical).
- It must be higher than the last tag and not already exist (`gh release view vX.Y.Z` fails).
- Nothing to release (no commit since the last tag) → say so and stop.

### 3. Bump the number everywhere

- Update `web/src/site.ts` and the README example to the new number. Whatever old number they hold (they may lag behind the last tag), replace it.
- Then look for any other hand-written version that may have appeared:
  `grep -rnE "\b[0-9]+\.[0-9]+\.[0-9]+\b" README.md web/src web/public install.sh`
  Report what you find; change only what is clearly "the current version", never history (release notes, changelog lines, tests).
- Check the site still builds: `cd web && npm run build`.

### 4. Draft the release notes

- Material: `git log <last tag>..HEAD`, and the merged PRs since then (`gh pr list --state merged --search "merged:>=<date of last tag>"`, then `gh pr view <n>` for their descriptions).
- Style: read the previous release (`gh release view <last tag> --json body -q .body`) and match it:
  - one opening sentence saying what the version brings, with the PR number(s) in parentheses;
  - bullets starting with a short **bold** phrase, written for a selector, not a developer: what you see and do, UI words in backticks (`CANCEL ALL`), no engine jargon;
  - smaller fixes as plain bullets at the end;
  - always end with, unchanged:

    ````
    From 0.4.0 on, the update banner brings this version in one click. From 0.3.0 or earlier:

    ```sh
    curl -fsSL https://raw.githubusercontent.com/yoanbernabeu/DubStemMix/main/install.sh | sh
    ```
    ````
- Only what is actually in the commits. Plan or doc commits (TODO, PRD, ideas) are not features.
- Write the notes to a file in the scratchpad.

### 5. Show and wait for the OK

Show the user, in short:

- the number (`0.9.0 → 0.10.0`);
- the files changed (`git diff --stat`) and anything odd found in step 3;
- the full release notes.

Wait for an explicit yes. Changes to the notes or the number → apply, show again.

### 6. Publish

1. Commit `Release X.Y.Z` (only the bump files), with the attribution lines the session asks for; push to `origin main`.
2. `gh release create vX.Y.Z --target main --title "DubStemMix X.Y.Z" --notes-file <notes file>` (this creates the tag and triggers the build).
3. Follow the build: find the run with `gh run list --workflow Release --limit 1`, then `gh run watch <id> --exit-status`.
4. Check: `gh release view vX.Y.Z --json assets -q '.assets[].name'` lists `DubStemMix-X.Y.Z.zip`, and the Pages run of the bump commit succeeded.

### 7. Report

The release link, the zip present or not, the site redeployed or not. If the build failed: say so with the failing step's log (`gh run view <id> --log-failed`), and do not delete or redo anything without asking.
