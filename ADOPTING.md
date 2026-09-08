# Adopting this pipeline for another Unity game

This describes how to set the CI/CD pipeline up on a Unity game that does not have it yet.
For how the pipeline behaves once running, see [README.md](README.md).

What you get: every push runs the Unity tests and builds a WebGL player; every pull request
gets its own preview build with a link posted as a comment; every `v*` tag produces an
immutable release build, a `CHANGELOG.md` entry, and a GitHub Release.

The design goal is that a second game needs **one file of its own** and nothing else
invented. Everything game-specific lives in `ci.yml`; the pipeline itself takes it as
inputs.

---

## 1. Prerequisites

Before starting, check these. Each one has bitten this setup at least once.

| Requirement | How to check | If it fails |
|---|---|---|
| The project's Unity version has a GameCI editor image | Look for `ubuntu-<version>-webgl-3` on [hub.docker.com/r/unityci/editor/tags](https://hub.docker.com/r/unityci/editor/tags) | Upgrade the project to a covered version, or build on a self-hosted runner |
| The project builds WebGL locally | Build once from the editor | Fix it locally first; CI will not be easier to debug |
| At least one enabled scene in Build Settings | File, Build Profiles | The build fails immediately with a clear error |
| A Unity licence you can put in CI | See secrets below | Tests cannot run at all without it |
| A Cloudflare account with R2 | Only if you want deploys | Set `deploy: false` and you still get tests and build artifacts |

**Size warning.** A standard GitHub-hosted runner has 4 cores, 16 GB RAM and about 14 GB of
free disk. A large project can exhaust it: World Sim's first attempt died after two hours
with `The hosted runner lost communication with the server`, which is the OOM killer or a
full disk. The build job frees roughly 25 GB and adds 16 GB of swap to compensate. If a
project still fails that way, the answer is a self-hosted runner via the `runs-on` input,
not more tuning.

---

## 2. Files to copy

Only the callers. Copy these three from [`examples/`](examples/) into the game's
`.github/workflows/`, then edit the `with:` block in each.

| File | Purpose |
|---|---|
| `ci.yml` | **The main caller. This is the file you edit.** |
| `cleanup-preview.yml` | Removes a PR's preview build from R2 when the PR closes. |
| `rollback.yml` | Manual rollback of the live build. |

The pipeline itself, and the `ci/*.sh` scripts it runs, stay in this repo. Jobs that need
a script check this repo out themselves at `github.job_workflow_sha`, the exact commit the
running workflow came from, so scripts and workflow can never be a version apart.

### Only if the game has no Unity 6 Build Profile

| File | Purpose |
|---|---|
| `Assets/Editor/CI/BuildScript.cs` | Batch-mode build entry point, `CI.BuildScript.Build`. |

If the game *does* have a build profile, set the `build-profile` input instead and CI builds
through it, which guarantees CI and local builds cannot drift apart. `BuildScript.cs` is the
fallback for projects without one.

### Optional but recommended

| File | Purpose |
|---|---|
| `Assets/Tests/EditMode/` | Give the test job something real to run. |

A project with no tests still passes the test job; it just verifies that the editor opens and
compiles the project, which is worth more than it sounds. The World Sim tests assert that
Build Settings has enabled scenes that exist on disk, which catches a broken build in ten
minutes rather than forty.

---

## 3. Secrets

Set these under **Settings, Secrets and variables, Actions**. Use *organisation* secrets if
several games share them, so each new repo inherits them via `secrets: inherit`.

### Unity, required for tests and builds

Pick one licence type.

| Secret | Personal | Plus / Pro |
|---|---|---|
| `UNITY_EMAIL` | required | required |
| `UNITY_PASSWORD` | required | required |
| `UNITY_LICENSE` | required, full contents of the `.ulf` file | not used |
| `UNITY_SERIAL` | not used | required |

Notes:

- A `.ulf` activated on a developer's machine carries machine bindings and *may* be rejected
  inside the Linux build container. If activation fails, generate one from inside CI using
  [game-ci's activation flow](https://game.ci/docs/github/activation). World Sim's local
  `.ulf` was accepted, so try yours before assuming it will not be.
- A Personal licence permits one activation at a time, so parallel builds across games can
  collide.
- **Consider a dedicated Unity account for CI.** Anyone who can push a workflow to the repo
  can print these secrets, so the blast radius of `UNITY_PASSWORD` is your whole Unity
  identity, including Asset Store purchases. A throwaway account limits that.

### Cloudflare R2, required only if `deploy: true`

| Secret | Where it comes from |
|---|---|
| `R2_ACCOUNT_ID` | The bare account hash from the S3 endpoint `https://<hash>.r2.cloudflarestorage.com`. **Hash only**, no scheme, no domain. |
| `R2_ACCESS_KEY_ID` | R2, Manage API tokens, Create API token |
| `R2_SECRET_ACCESS_KEY` | Shown once at token creation |

Create the token with **Object Read & Write**, scoped to the one bucket. The "Token value"
Cloudflare also shows is a bearer token for Cloudflare's REST API and is **not used** here;
the pipeline talks to R2 over the S3-compatible API.

A wrong value here is caught in about fifteen seconds by the credential preflight in the
`config` job, before any build time is spent.

---

## 4. Cloudflare R2 setup

Do this once per organisation, not once per game. All games share one bucket and are
separated by key prefix, so adding a game needs no new infrastructure.

1. **Create a bucket**, e.g. `games`.
2. **Create the scoped API token** as above.
3. **Make the bucket publicly readable**, one of:
   - **Custom domain** (bucket Settings, Public access, Connect domain). Correct for anything
     players will see.
   - **Public Development URL** (`r2.dev`). One click, no domain needed, but Cloudflare
     rate-limits it and advises against production traffic. Fine for testing.
4. Put the resulting origin in `public-base-url`, **without a trailing slash**.

**R2 has no directory index.** `…/branch/main/` returns 404; `…/branch/main/index.html`
works. Every link the pipeline generates includes `index.html` for this reason.

---

## 5. Repository settings

**Permissions.** `ci.yml` must declare these, because a called workflow cannot grant itself
more than its caller holds:

```yaml
permissions:
  contents: write        # release job: create releases, commit CHANGELOG.md
  checks: write          # test job: publish the test check run
  pull-requests: write   # deploy job: post the preview link
```

`contents: write` applies to every run, not just tag runs. If that is more than you want,
set `create-release: false` and drop it back to `contents: read`.

**Environments** (Settings, Environments). Optional. Creating one named `production` with
required reviewers makes tag promotion to `<game>/live/` wait for a human click. The
`preview`, `branch` and `release` environments are created automatically and need no rules.

---

## 6. Write the caller

Copy `ci.yml` and change the `with:` block. This is the entire per-game setup:

```yaml
name: CI

on:
  pull_request:
    paths-ignore: ['**.md']
  push:
    branches: [main]
    tags: ['v*']
    paths-ignore: ['**.md']
  workflow_dispatch:

permissions:
  contents: write
  checks: write
  pull-requests: write

jobs:
  unity:
    uses: TheFriedHashbrown/unity-game-ci/.github/workflows/unity-game.yml@v1
    with:
      game-id: tessera
      build-targets: '["WebGL"]'
      build-profile: 'Assets/Settings/Build Profiles/Web - Release.asset'
      test-mode: all
      development-build: ${{ github.event_name == 'pull_request' }}
      deploy: true
      r2-bucket: games
      public-base-url: https://games.example.com
    secrets: inherit
```

And `cleanup-preview.yml`:

```yaml
name: Cleanup preview

on:
  pull_request:
    types: [closed]

jobs:
  cleanup:
    uses: TheFriedHashbrown/unity-game-ci/.github/workflows/cleanup-preview.yml@v1
    with:
      game-id: tessera
      r2-bucket: games
    secrets: inherit
```

`game-id` must be unique across games sharing a bucket: it is the top-level key prefix.

---

## 7. Input reference

| Input | Type | Default | Notes |
|---|---|---|---|
| `game-id` | string | **required** | Slug used for build names and R2 key prefixes. |
| `project-path` | string | `.` | Folder holding `Assets/` and `ProjectSettings/`. Set to e.g. `unity` for a nested project. |
| `unity-version` | string | *auto* | Read from `ProjectVersion.txt` unless pinned. |
| `build-targets` | string | `["WebGL"]` | JSON array. Extra targets build and upload as artifacts but are not deployed. |
| `build-profile` | string | `''` | Path to a Unity 6 Build Profile `.asset`. Empty falls back to `CI.BuildScript.Build`. |
| `test-mode` | string | `all` | `all`, `editmode`, `playmode`, `none`. |
| `coverage-filters` | string | `''` | e.g. `+Tessera*`. Empty disables coverage. |
| `webgl-compression` | string | `''` | `brotli`, `gzip`, `disabled`. Empty leaves the project setting alone. Ignored when `build-profile` is set. |
| `development-build` | boolean | `false` | The example enables it for pull requests only. |
| `deploy` | boolean | `true` | Set false for tests and build artifacts without R2. |
| `r2-bucket` | string | `''` | Bucket name. |
| `public-base-url` | string | `''` | Public origin, no trailing slash. Empty skips the smoke test and PR comments. |
| `promote-tags` | boolean | `true` | On a `v*` tag, also publish to `<game-id>/live/`. |
| `create-release` | boolean | `true` | On a `v*` tag, update `CHANGELOG.md` and create a GitHub Release. |
| `prune` | boolean | `true` | Delete objects under the prefix that are not in this build. |
| `build-timeout-minutes` | number | `180` | Hang guard. Cold first builds of a large project can exceed two hours. |
| `runs-on` | string | `ubuntu-latest` | Runner for the build job. Use a self-hosted label for projects that will not fit. |

---

## 8. Which version to pin

Pin the major tag:

```yaml
uses: TheFriedHashbrown/unity-game-ci/.github/workflows/unity-game.yml@v1
```

`v1` is a moving tag pointing at the newest 1.x, the same convention as
`actions/checkout@v4`, so bug fixes reach every game without touching any of them. Pin an
exact version like `@v1.2.0` if a game needs to be insulated from that, and upgrade it
deliberately.

Never use `@main`: every push to the pipeline would hit every game immediately.

A change that breaks callers, such as renaming an input, gets a new major rather than
moving `v1`. See the pipeline repo's README for how releases are cut.

---

## 9. Things that will bite

Each of these cost real debugging time on World Sim.

- **`docker failed with exit code 125`** means Docker could not start the container, usually
  disk. Do not relocate Docker's data-root to fix it; that broke the daemon and produced the
  same error faster. Free space on `/` instead.
- **Unity does not content-hash WebGL filenames.** Every build writes the same
  `<game>.wasm.br`. So `Cache-Control: immutable` is only safe under `release/<tag>/`, which
  is never rewritten. The pipeline passes `--immutable` for exactly that prefix. Getting this
  wrong pins returning players to the build they first loaded, for a year.
- **Compression settings live in the build profile**, and a profile's override wins over
  ProjectSettings. Set Brotli with decompression fallback **off**: `deploy-r2.sh` sets
  `Content-Encoding` per file, so the fallback only adds loader weight and hides header
  problems. The `config` job warns if a profile disables compression.
- **Verify with `Accept-Encoding: br`.** Cloudflare transparently decompresses for clients
  that do not advertise brotli, which hides the stored `Content-Encoding` and makes a naive
  check pass while verifying nothing.
- **Version numbers count commits since the last tag.** Tag at or above the number CI last
  built. If CI is producing `1.2.5`, tag `v1.2.5` or `v1.3.0`, never `v1.2.1`.
- **Pushing to a branch with a running build**: `cancel-in-progress` is scoped to pull
  requests precisely so a push to `main` cannot discard a two-hour build.
- **`CHANGELOG.md` is generated.** Hand edits are overwritten on the next release.

---

## 10. Verify it worked

In order, cheapest first:

1. **Push to `main`.** `Resolve config` should report the editor version, the derived
   version, the deploy prefix, and `R2 bucket '<name>' reachable.`
2. **Tests** should publish a check run and upload a results artifact.
3. **Build** should upload a `<game-id>-WebGL` artifact. The first run is cold and slow;
   later runs reuse the `Library/` cache.
4. **Deploy** should list the uploaded files, then the smoke test should print
   `Checking N player files` with `[br]` beside the compressed ones. If it reports finding no
   assets, it fails rather than passing silently.
5. **Open the URL**, including `index.html`. CI proves the bytes and headers are right; only
   a browser proves the game boots.
6. **Open a pull request** to confirm the preview build and its comment, then close it to
   confirm cleanup removes the objects.
7. **Tag `v0.1.0`** to exercise the release path: immutable caching, `CHANGELOG.md`, the
   GitHub Release, and the production gate.
