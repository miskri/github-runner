#!/usr/bin/env bash
set -uo pipefail

CONFIG=/etc/github-runner/config.json

log() { echo "[github-runner] $*"; }

if ! jq -e 'type == "object"' "$CONFIG" >/dev/null 2>&1; then
    log "cannot read $CONFIG - copy config.example.json to config.json and fill it in"
    exit 1
fi

NAME="$(jq -r '.runner.name // "docker-runner"' "$CONFIG")"
LABELS="$(jq -r '.runner.labels // [] | join(",")' "$CONFIG")"
VAR_NAME="$(jq -r '.variable.name // "RUNS_ON"' "$CONFIG")"
VAR_VALUE="$(jq -r '.variable.value // "self-hosted"' "$CONFIG")"

declare -A TOKENS=()
REPOS=()
while IFS= read -r entry; do
    repo="$(jq -r '.name // ""' <<<"$entry")"
    token="$(jq -r '.token // ""' <<<"$entry")"
    if [[ "$repo" != */* || -z "$token" ]]; then
        log "ignoring repository entry \"$repo\": expected {\"name\": \"owner/name\", \"token\": \"...\"}"
        continue
    fi
    TOKENS["$repo"]="$token"
    REPOS+=("$repo")
done < <(jq -c '.repositories // [] | .[]' "$CONFIG")

if [ "${#REPOS[@]}" -eq 0 ]; then
    log "no repositories configured - add them to \"repositories\" in config.json"
    exit 1
fi

PIDS=()
ACTIVE=()

as_runner() {
    setpriv --reuid=runner --regid=runner --init-groups \
        env HOME=/home/runner USER=runner "$@"
}

runner_dir() { echo "/runners/${1//\//__}"; }

api() {
    local method="$1" repo="$2" path="$3" body="${4:-}"
    local args=(-fsS -X "$method"
                -H "Accept: application/vnd.github+json"
                -H "X-GitHub-Api-Version: 2022-11-28")
    [ -n "$body" ] && args+=(-d "$body")
    curl "${args[@]}" \
        -K <(printf 'header = "Authorization: Bearer %s"\n' "${TOKENS[$repo]}") \
        "https://api.github.com/repos/$repo/$path"
}

runner_token() {
    api POST "$1" "actions/runners/$2-token" | jq -er .token
}

set_variable() {
    local repo="$1"
    api PATCH "$repo" "actions/variables/$VAR_NAME" \
        "$(jq -nc --arg v "$VAR_VALUE" '{value: $v}')" >/dev/null 2>&1 \
    || api POST "$repo" "actions/variables" \
        "$(jq -nc --arg n "$VAR_NAME" --arg v "$VAR_VALUE" '{name: $n, value: $v}')" >/dev/null
}

start_runner() {
    local repo="$1" dir token
    dir="$(runner_dir "$repo")"

    if [ ! -d "$dir" ]; then
        cp -a /opt/runner "$dir"
    fi
    rm -f "$dir/.runner" "$dir/.credentials" "$dir/.credentials_rsaparams"

    if ! token="$(runner_token "$repo" registration)"; then
        log "SKIP $repo: cannot get a registration token (check the repo name and the token's Administration permission)"
        return 1
    fi

    local args=(--unattended --url "https://github.com/$repo" --token "$token"
                --name "$NAME" --work _work --replace)
    [ -n "$LABELS" ] && args+=(--labels "$LABELS")

    if ! (cd "$dir" && as_runner ./config.sh "${args[@]}"); then
        log "SKIP $repo: registration failed"
        return 1
    fi

    (cd "$dir" && exec setpriv --reuid=runner --regid=runner --init-groups \
        env HOME=/home/runner USER=runner ./run.sh) &
    PIDS+=($!)
    ACTIVE+=("$repo")
    log "started runner for $repo"

    if set_variable "$repo"; then
        log "$repo: $VAR_NAME=$VAR_VALUE"
    else
        log "WARNING $repo: could not set $VAR_NAME (check the token's Variables permission); workflows stay on GitHub-hosted runners"
    fi
}

shutdown() {
    local code="${1:-0}" repo dir token
    trap '' TERM INT
    log "stopping..."

    for repo in "${ACTIVE[@]}"; do
        if api DELETE "$repo" "actions/variables/$VAR_NAME" >/dev/null; then
            log "$repo: $VAR_NAME removed"
        else
            log "WARNING $repo: could not remove $VAR_NAME - delete it manually or jobs will queue"
        fi
    done

    if [ "${#PIDS[@]}" -gt 0 ]; then
        kill -TERM "${PIDS[@]}" 2>/dev/null
        pkill -INT -f Runner.Listener 2>/dev/null
        wait "${PIDS[@]}" 2>/dev/null
    fi

    for repo in "${ACTIVE[@]}"; do
        dir="$(runner_dir "$repo")"
        if token="$(runner_token "$repo" remove)"; then
            (cd "$dir" && as_runner ./config.sh remove --token "$token") \
                && log "unregistered runner for $repo"
        else
            log "could not unregister runner for $repo (it will show as offline)"
        fi
    done
    exit "$code"
}

trap 'shutdown 0' TERM INT

for repo in "${REPOS[@]}"; do
    start_runner "$repo" || true
done

if [ "${#PIDS[@]}" -eq 0 ]; then
    log "no runner could be started"
    exit 1
fi

log "${#PIDS[@]} runner(s) online: ${ACTIVE[*]}"

wait -n "${PIDS[@]}"
log "a runner process exited unexpectedly"
shutdown 1
