# Operating the pipeline

How it behaves once a game is set up. For first-time setup see [ADOPTING.md](ADOPTING.md).

Throughout, `<game>` is the `game-id` input.

## Where builds land

| Trigger | R2 prefix | Kept? |
|---|---|---|
| Pull request | `<game>/preview/pr-<n>/` | Until the PR closes, then deleted |
| Push to `main` | `<game>/branch/main/` | Overwritten every push |
| Tag `v1.2.0` | `<game>/release/v1.2.0/` | **Permanently**, one per tag |
| Tag, then promotion | `<game>/live/` | Overwritten each promotion |

`release/<tag>/` is the only prefix with history, which is what makes rollback possible.
Pull request builds get Unity's Development flag; everything else is a release build.

R2 has no directory index, so a URL must name the file: `…/live/index.html`, not `…/live/`.

## Versioning

A plain `MAJOR.MINOR.PATCH`, no pre-release or build-metadata suffix, so it is valid on
every platform including iOS. Derived from the newest `v*` tag as
`MAJOR.MINOR.(PATCH + commits since that tag)`. A tagged build uses the tag verbatim. With
no tags yet it falls back to `0.1.<run number>`. The result becomes
`PlayerSettings.bundleVersion`, readable at runtime as `Application.version`.

**The one rule: tag at or above the number CI last built.** The patch counts commits, so
if CI has been producing `1.2.5`, tag `v1.2.5` or `v1.3.0`. Tagging `v1.2.1` would publish
a release numerically older than builds testers already have. The originating commit is
recorded in the run summary rather than in the version string.

## What a `v*` tag does

1. Deploys to `<game>/release/<tag>/`, cached immutably since that prefix is never rewritten.
2. Regenerates `CHANGELOG.md` and commits it to `main`.
3. Creates a GitHub Release, with that tag's changelog section as the body and the player
   attached as `<game>-<tag>-webgl.zip`.
4. Promotes to `<game>/live/`, gated by the `production` environment if the repo's plan
   supports protection rules.

Re-running a tag updates the existing release rather than failing.

## CHANGELOG.md

`ci/changelog.sh` rebuilds the whole file from the `v*` tags every time rather than
appending. That makes it idempotent: running it twice changes nothing, a release that
fails halfway leaves no half-written file, and running it locally produces exactly what CI
produces.

Each section lists the non-merge commits between one tag and the previous one, found via
`git describe` on the tag's parent, so it stays correct even if tags are created out of
version order. The release body is extracted from this same file, so the two cannot
disagree about what shipped.

The file is **generated, so hand edits are lost** on the next release; prose belongs in
commit subjects. The commit updating it lands on `main` *after* the tag, so a tagged
commit never contains its own changelog entry. That push uses the built-in token and
touches only markdown, so it cannot trigger another build.

## Rollback

**Actions → Rollback → Run workflow.** Leave the tag empty to go back one release, or name
a tag to restore that one. Two or three minutes, no build.

Every promotion and rollback writes `<game>/live/deployed.json` recording the live tag. The
workflow reads it over the S3 API, so no CDN cache can answer with a stale one, then walks
`gh release list` newest-first and takes the first tag that is not current. Without a
marker it refuses to guess and asks for an explicit tag.

The build comes from the **GitHub Release asset**, not from R2. An S3 server-side copy
carries object metadata, and release objects hold `Cache-Control: immutable`, which is
correct under `release/<tag>/` and harmful on `live/`; re-deploying through
`ci/deploy-r2.sh` sets every header from scratch via the one proven code path. Release
assets also never expire and live outside Cloudflare, so rollback survives losing the
bucket.

Two limits: it only covers releases that have a `*-webgl.zip` attached, and rolling
`live/` back does not change `main`, so revert the bad commit in git too or the next
release reintroduces it.

## Why the upload is file-by-file

R2 is object storage, not a web server: the browser gets exactly the `Content-Type` and
`Content-Encoding` stored on the object. `aws s3 sync` sets neither, which produces the
classic `Unable to parse Build/<game>.framework.js.br`. So `ci/deploy-r2.sh` derives
metadata per file, mapping `.wasm.br` to `application/wasm` plus `Content-Encoding: br`.

`ci/verify-deploy.sh` then re-fetches the deployed page and every player file it
references, failing the job if any 404s or loses its encoding. It sends
`Accept-Encoding: br`, because Cloudflare transparently decompresses for clients that do
not advertise it, which would hide the very header being checked.

Caching is deliberately split. `index.html` always revalidates. Player files are cached
immutably **only** when deployed with `--immutable`, which the pipeline passes for
`release/<tag>/` alone. Unity reuses the same `<game>.wasm.br` and `<game>.data.br`
filenames on every build, so marking them immutable under a rewritten prefix pins
returning players to whichever build they loaded first, for a year, while `index.html`
updates around them.

## Build modes

`build-mode` decides where Unity actually runs.

| Mode | Runs where | Licence |
|---|---|---|
| `gameci` (default) | GameCI Docker image on a hosted runner | Needs `UNITY_LICENSE` or `UNITY_SERIAL` |
| `native` | The Unity install on a self-hosted runner | Uses that machine's own activation; no secret |

**Unity Personal can no longer activate in a container.** Manual `.ulf` activation has been
withdrawn for Personal, and there is no serial, so `gameci` mode effectively requires a
Plus or Pro seat. `native` mode sidesteps this by using a machine Unity Hub has licensed.

Native mode also avoids the hosted runner's memory and disk limits, which a large WebGL
project can exhaust outright, and keeps `Library/` warm between runs so builds take 10-20
minutes rather than hours. It costs no Actions minutes.

The trade: the machine must be on for queued jobs to run, and workflow code executes on it
with that user's permissions. Fine for a private repo with trusted collaborators; never
attach a self-hosted runner to a public repo.

Only test and build move. `config`, `deploy`, `promote` and `release` stay on hosted
runners, costing a minute or two of quota and keeping R2 uploads off the machine.

### Setting up the runner

1. **Settings, Actions, Runners, New self-hosted runner**, pick Windows x64, and run the
   download and configure commands it shows, in a folder such as `C:\actions-runner`.
2. When `config.cmd` asks for labels, enter the one you will put in `runs-on`, for example
   `unity-win`. Keep the default work folder.
3. Say no to running as a service the first time and start it with `run.cmd`, so you can
   watch the first run. Once it is green, `config.cmd remove` and reconfigure as a service
   under your own user account: Unity needs a real user profile, and PlayMode tests need a
   display.
4. In the game's `ci.yml`, set `build-mode: native` and `runs-on: <your label>`.

The runner clones the repo into its own `_work` folder and never touches your working
copy, so the editor can stay open while CI builds. The first run is cold; later runs reuse
that `Library/`.

Upgrading the project's Unity version means installing that version through the Hub on the
runner machine first. The editor is located via `unity-editor-path`, which defaults to
`C:\Program Files\Unity\Hub\Editor\{version}\Editor\Unity.exe`.

## Refreshing the Unity licence

Only relevant in `gameci` mode; `native` mode needs no licence secret at all.

A Personal `.ulf` carries a timestamp that Unity's licensing service validates, and it
goes stale. Exporting one from a developer machine also binds it to that machine, and
opening the editor locally can supersede it. When that happens the editor refuses to
start and the job fails like this, with no Unity output and no test results:

```
[Licensing::Module] Loading manual activation license file UnityLicenseFile.ulf.
[Licensing::Client] Error: Code 400 while processing request (status: TimeStamp validation failed)
Unclassified error occured while trying to activate license.
```

From the outside this is a bare `exit code 1`, which looks like a broken test rather than
a licensing problem. The give-away is the absence of any Unity output.

There is **no CI-side activation**: GameCI retired `unity-request-activation-file`, and it
now fails with "This action is no longer supported". The process is local.

1. Close the Unity editor.
2. Generate an activation request, which writes `Unity_v<version>.alf` into the working
   directory:

   ```bash
   "/c/Program Files/Unity/Hub/Editor/<version>/Editor/Unity.exe" \
     -batchmode -nographics -quit -createManualActivationFile -logFile -
   ```

3. Upload the `.alf` at <https://license.unity3d.com/manual>, choosing Unity Personal and
   "I don't use Unity in a professional capacity".
4. Paste the **entire** `.ulf` you get back into the `UNITY_LICENSE` secret.
5. Re-run the failed job.

GameCI's own documentation tells you to copy `C:\ProgramData\Unity\Unity_lic.ulf`. On
Unity 6 that file usually does not exist: the normal licence is an entitlement XML under
`%LOCALAPPDATA%\Unity\licenses`, and a `.ulf` only appears once a manual activation like
the above creates one.

An activation file is single use, and the resulting `.ulf` is bound to the machine that
generated it.

## Running the pieces locally

```bash
"/c/Program Files/Unity/Hub/Editor/<version>/Editor/Unity.exe" -quit -batchmode -nographics \
  -projectPath . -executeMethod CI.BuildScript.Build -buildTarget WebGL \
  -CIBuildVersion 0.0.1-local -logFile -
```

```bash
R2_ACCOUNT_ID=… R2_ACCESS_KEY_ID=… R2_SECRET_ACCESS_KEY=… \
  ci/deploy-r2.sh --source build/WebGL/<game> --bucket games \
    --prefix <game>/branch/local --dry-run
```

```bash
ci/verify-deploy.sh https://games.example.com/<game>/live/
ci/changelog.sh
```

## Troubleshooting

| Symptom | Cause |
|---|---|
| `Unable to parse Build/*.br` | Object uploaded without `Content-Encoding`; check the deploy job output. |
| `docker failed with exit code 125` | Docker could not start the container, usually disk. Free space on `/`; do not relocate Docker's data-root. |
| `No space left on device` | WebGL and IL2CPP on a hosted runner. The prepare step frees ~25 GB and adds swap; past that use a self-hosted runner via `runs-on`. |
| `The hosted runner lost communication with the server` | The runner process died: OOM killer during the WebGL link, or a full disk. Same fixes. |
| `License is not activated` | Missing or expired Unity secrets. |
| `TimeStamp validation failed`, then exit 1 with no Unity output at all | The `UNITY_LICENSE` `.ulf` has gone stale. Refresh it: see *Refreshing the Unity licence* below. |
| PlayMode tests fail only in CI | CI runs `-nographics`; guard rendering-dependent assertions or move them to EditMode. |
| Players stuck on an old build | A mutable prefix was cached immutably. Should not happen now, but a hard refresh clears it. |
| First run is very slow | Cold `Library/` cache. Later runs on the same target reuse it. |
