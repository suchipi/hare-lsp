# Prefer Latest Versions When Adding Dependencies

When adding a new dependency, default to the latest released version. This applies to every kind of dependency declaration in the repo, including but not limited to:

- GitHub Actions in `.github/workflows/` (e.g. `actions/checkout@vN`, `dorny/paths-filter@vN`).
- npm packages in `package.json` / `package-lock.json`.
- Docker base images (`FROM alpine:edge`, etc.).
- Vendored third-party code under `hare/` or elsewhere.
- Anything else fetched or pinned by version.

## How to apply

Before writing the version into a file, look it up. Do not guess or copy a version from another file - that file may itself be stale. Sources:

- GitHub Actions: `gh api repos/<owner>/<repo>/releases/latest --jq '.tag_name'`.
- npm packages: `npm view <package> version`.
- Anything else: the upstream's release page or registry.

For GitHub Actions, use the major-version tag (e.g. `@v6`, not `@v6.0.2`) unless there's a specific reason to pin tighter - the major tag tracks the latest minor/patch automatically.

## When to deviate

Use an older version only when there's a concrete reason, and call it out in a comment next to the pin:

- A documented incompatibility with another pinned dependency.
- A known regression in the latest version that affects this project.
- A hard runtime/toolchain constraint (e.g. the runner doesn't support the Node version the action requires).

"It's what was there before" is not a reason. If you're editing a file that already pins old versions of things you aren't touching, leave them alone (that's a [surgical change](general-behavioral-guidelines.md) concern), but for anything you're adding or bumping, go to the latest.
