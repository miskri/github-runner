# github-runner

One container that runs self-hosted GitHub Actions runners for a list of
repositories. Start it and workflows run locally; stop it and they go back to
GitHub-hosted runners.

## How it works

On start, for every repository in `config.json` the container:

1. registers a runner in that repository
2. sets the repository variable `RUNS_ON=self-hosted`

On stop it deletes the variable first (so new jobs go back to GitHub-hosted
runners), then stops the runners and unregisters them

Workflows pick the runner through the variable:

```yaml
runs-on: ${{ vars.RUNS_ON || 'ubuntu-latest' }}
```

## Setup (once)

1. `cp config.example.json config.json` (the file is git-ignored)
2. For each repository create a fine-grained token at
   https://github.com/settings/personal-access-tokens/new
   - Repository access: only that repository
   - Repository permissions: **Administration → Read and write** (register
     the runner), **Variables → Read and write** (switch `RUNS_ON`)
3. Add the repository to `repositories` in `config.json`.
4. Use the `runs-on` line above in the repository's workflows.

## config.json

```json
{
  "runner": {
    "name": "mac-docker",
    "labels": ["docker"]
  },
  "tools": {
    "apt": ["python3", "build-essential"],
    "run": ["curl -fsSL https://deb.nodesource.com/setup_22.x | bash -", "apt-get install -y nodejs"]
  },
  "repositories": [
    { "name": "owner/name", "token": "github_pat_..." }
  ]
}
```

| Key | When it applies | Meaning |
| --- | --- | --- |
| `repositories[].name` | start | `owner/name` of the repository |
| `repositories[].token` | start | PAT for that repository |
| `runner.name` | start | runner name shown in Settings → Actions → Runners (default `docker-runner`) |
| `runner.labels` | start | extra labels; `self-hosted`, `Linux` and the CPU arch are added automatically |
| `variable.name`, `variable.value` | start | repository variable to set (default `RUNS_ON` = `self-hosted`) |
| `tools.apt` | build | apt packages installed into the image for workflow jobs |
| `tools.run` | build | shell commands run as root after the apt packages, for tools that are not in apt; the build fails on the first failing command |

`ca-certificates`, `curl`, `git`, `jq` and `procps` are always installed.

## Usage

```bash
docker compose up -d --build   # start
docker compose logs -f         # logs
docker compose down            # stop
```

- Changed repositories/runner/variable: `docker compose restart`.
- Changed tools: `docker compose up -d --build`. Only the tools layer is
  rebuilt, and only when tools itself changed

## Notes

- Jobs run as the unprivileged `runner` user without sudo, so they cannot
  install system packages themselves: list what pipelines need in `tools`
- Tokens stay out of reach of jobs. `config.json` is mounted read-only into a
  root-only directory, is never copied into the image (the build reads only
  its `tools` section through a build mount), and tokens are passed to `curl`
  through a file descriptor rather than the command line
- A repository whose runner cannot be registered is skipped with a log line;
  the others keep working. If `RUNS_ON` cannot be set, the runner stays
  online but workflows remain on GitHub-hosted runners
- The runner is Linux on the host CPU architecture (ARM64 on Apple Silicon).
- `RUNNER_VERSION` build arg defaults to `latest` (resolved at build time);
  pin it with `docker compose build --build-arg RUNNER_VERSION=2.338.2`
- Stopping gives running jobs and unregistration up to one minute
  (`stop_grace_period`)
- If the container dies without a clean stop (for example the host loses
  power), `RUNS_ON` stays set and jobs queue until the container is back.
  Delete the variable in Settings → Secrets and variables → Actions →
  Variables to return to GitHub-hosted runners right away
