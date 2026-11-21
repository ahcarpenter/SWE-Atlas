#!/usr/bin/env bash
# Which skills Claude Code sees in a task sandbox under a run config, with no model call:
#   scripts/check-skills.sh configs/claude-opus-5-5-skills-pack.yaml       the pack: 26 skills
#   scripts/check-skills.sh configs/claude-opus-5-5-skills-baseline.yaml   no pack: 0 skills
#   scripts/check-skills.sh <config.yaml> [qa|rf|tw [task]] [harbor args]  default: qa-6905333b74f22949d97ba9cc
# It runs the config's claude-code agent once on one task with verification off and every
# Anthropic credential removed from the environment. Claude Code is installed and started in the
# sandbox exactly as in a real run, reports the skills it loaded in its init event and then stops
# at authentication, so nothing reaches a model and no judge is called. Then it prints those
# skills, the Claude Code version and the --effort it was started with.
# Needs what run.sh needs except the judge: harbor and the Modal token (from .env or the environment).
set -euo pipefail

if [ ! -f "${1:-}" ]; then
  echo "usage: scripts/check-skills.sh <config.yaml> [qa|rf|tw [task]] [harbor args]" >&2
  exit 1
fi
config="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; shift
cd "$(dirname "$0")/.."

lane=qa task=qa-6905333b74f22949d97ba9cc
case "${1:-}" in
  qa|rf|tw)
    lane="$1"; shift
    if [ -n "${1:-}" ] && [ "${1#-}" = "$1" ]; then task="$1"; shift
    else task="$(ls "data/$lane" | head -n 1)"; fi ;;
esac

if [ -f .env ]; then set -a; . ./.env; set +a; fi
# No credential, no model call: drop every variable harbor's claude-code agent would forward.
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN CLAUDE_FORCE_OAUTH \
  ANTHROPIC_BASE_URL ANTHROPIC_API_BASE CLAUDE_CODE_USE_BEDROCK AWS_BEARER_TOKEN_BEDROCK
# harbor loads .env.local with lower priority than the environment, so it would restore them.
[ ! -f .env.local ] || { echo "check-skills: move .env.local aside first" >&2; exit 1; }

jobs_dir=jobs
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in -o|--jobs-dir) jobs_dir="${args[$((i + 1))]:-jobs}" ;; --jobs-dir=*) jobs_dir="${args[$i]#*=}" ;; esac
done
name="check-skills-$(basename "$config" .yaml)-$(date +%Y%m%d-%H%M%S)"

# Claude Code exits on the missing credential, so the agent step is expected to fail.
harbor run -c "$config" -p "data/$lane" -i "$task" -k 1 -n 1 -r 0 --disable-verification -y \
  --job-name "$name" "$@" || true

python3 - "$jobs_dir/$name" "$config" "$task" <<'EOF'
import glob, json, os, re, sys

job, config, task = sys.argv[1:4]
trials = sorted(glob.glob(os.path.join(job, "*", "agent", "claude-code.txt")))
if not trials:
    sys.exit(f"check-skills: no claude-code.txt under {job}; see {job}/*/trial.log")
trial = os.path.dirname(os.path.dirname(trials[0]))

init, result = None, None
for line in open(trials[0], encoding="utf-8", errors="replace"):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("type") == "system" and event.get("subtype") == "init" and init is None:
        init = event
    elif event.get("type") == "result":
        result = event
if init is None:
    sys.exit(f"check-skills: Claude Code printed no init event; see {trials[0]}")

log = open(os.path.join(trial, "trial.log"), encoding="utf-8", errors="replace").read()
flags = [l for l in log.splitlines() if "claude --verbose" in l]
effort = re.search(r"--effort[ =](\S+)", flags[-1]) if flags else None

skills = sorted(s.get("name", str(s)) if isinstance(s, dict) else str(s)
                for s in init.get("skills") or [])
usage = (result or {}).get("usage") or {}
tokens = sum(v for k, v in usage.items() if k.endswith("_tokens") and isinstance(v, int))
cost = (result or {}).get("total_cost_usd") or 0
source = init.get("apiKeySource", "?")
calls = "none" if tokens == 0 and not cost else "MADE"
print(f"config:       {os.path.relpath(config)}")
print(f"task:         {task} (trial {trial})")
print(f"claude code:  {init.get('claude_code_version', '?')}, model {init.get('model', '?')}")
print(f"effort:       {effort.group(1) if effort else 'not set (Claude Code default)'}")
print(f"model calls:  {calls} (credential source {source}, {tokens} tokens, ${cost})")
pack = {d for d in os.listdir(".agents/skills") if os.path.isfile(f".agents/skills/{d}/SKILL.md")}
seen = [s for s in skills if s in pack]
print(f"pack skills:  {len(seen)} of the {len(pack)} in .agents/skills")
for skill in seen:
    print(f"  {skill}")
other = [s for s in skills if s not in pack]
print(f"other skills: {len(other)}{' (' + ', '.join(other) + ')' if other else ''}")
sys.exit(0 if calls == "none" else 1)
EOF
