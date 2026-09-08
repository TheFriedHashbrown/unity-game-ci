# unity-game-ci

One CI/CD pipeline for all our Unity games: **test → build → deploy WebGL to Cloudflare R2**,
with PR previews, tagged releases, generated changelogs, and one-click rollback.

A game adopts it by adding three small caller files. Everything else lives here.

**Setting it up on a game? Start with [ADOPTING.md](ADOPTING.md).**
**Already running and want to know how it behaves? See [OPERATING.md](OPERATING.md).**

```yaml
# .github/workflows/ci.yml in the game repo
jobs:
  unity:
    uses: TheFriedHashbrown/unity-game-ci/.github/workflows/unity-game.yml@v1
    with:
      game-id: tessera
      build-profile: 'Assets/Settings/Build Profiles/Web - Release.asset'
      r2-bucket: games
      public-base-url: https://games.example.com
    secrets: inherit
```

## What's here

| Path | Purpose |
|---|---|
| `.github/workflows/unity-game.yml` | The pipeline: config, test, build, deploy, promote, release. |
| `.github/workflows/cleanup-preview.yml` | Removes a PR's preview build from R2 when the PR closes. |
| `.github/workflows/rollback.yml` | Puts a previous release back on `live/`. |
| `ci/deploy-r2.sh` | Uploads a build to R2 with the headers Unity WebGL requires. |
| `ci/verify-deploy.sh` | Post-deploy smoke test against the public URL. |
| `ci/changelog.sh` | Regenerates `CHANGELOG.md` from `v*` tags. |
| `examples/` | The caller files to copy into a game repo. |
| `template/` | `BuildScript.cs`, needed only by games without a Unity 6 Build Profile. |

## Versioning

Callers should pin to a major tag:

| Reference | Behaviour |
|---|---|
| `@v1` | Moving tag, always the newest 1.x. Bug fixes reach every game automatically. |
| `@v1.2.0` | Frozen. Each game upgrades deliberately. |
| `@main` | Every push hits every game immediately. Don't. |

`@v1` is the intended default, matching how `actions/checkout@v4` works. Cut a new major
only for a change that breaks callers, such as renaming or removing an input.

The pipeline fetches its own scripts using `github.job_workflow_sha`, the exact commit the
running workflow came from. So the scripts always match the workflow version, whatever ref
a caller pinned, and a moving `v1` tag can never pair a new workflow with old scripts.

### Releasing a change

```bash
git commit -m "Fix cache headers on live/"
git tag v1.1.0
git push origin main v1.1.0
git tag -f v1        # move the major tag
git push -f origin v1
```

Anything touching `deploy-r2.sh`, cache headers, or the release path is worth testing on
one game before moving `v1`, since moving it ships to all of them at once.

## Why this repo is public

Making it public is not about the code being interesting. It removes a class of confusing
permission failures: a private repo's workflows can only be reused by other repos with
explicit access configured, and the error when that is wrong is unhelpful. Nothing here is
secret; every credential lives in the calling repo and reaches jobs through
`secrets: inherit`.

Note this does **not** change Actions billing. Minutes are charged to the repository where
the run happens, which is always the calling game repo. A public pipeline repo does not
make a private game's builds free.

## Requirements it assumes

- The game's Unity version has a GameCI editor image.
- The game repo holds the R2 and Unity secrets and passes them with `secrets: inherit`.
- One R2 bucket shared across games, separated by `<game-id>/` key prefix.

[ADOPTING.md](ADOPTING.md) covers all of this in order, including the failures worth
skipping.
