# Running SWE Atlas from a Claude Code cloud session

This branch runs `./run.sh` from a Claude Code cloud session (claude.ai/code, the Claude app or
`claude --cloud`) and compares Claude Code with and without the
[addyosmani/agent-skills](https://github.com/addyosmani/agent-skills) pack.

**What runs where.** The cloud session's VM runs harbor. Harbor starts every task in a Modal
sandbox, and both the agent under evaluation and the judge run inside those sandboxes. So the VM
itself only talks to Modal (and to PyPI while it is set up); the agent's model API and the judge
endpoint are reached from Modal, under each task's own network allowlist.

## The pack and its baseline

| Config | Agent |
|---|---|
| `configs/claude-opus-5-5-skills-pack.yaml` | the `claude-opus-5-5.yaml` leaderboard settings (claude-code 2.1.293, effort max, web tools off, 3 attempts) plus `skills: [.agents/skills]` |
| `configs/claude-opus-5-5-skills-baseline.yaml` | the same file without `skills` |

Harbor uploads each skill under `.agents/skills` into the task sandbox, and its claude-code agent
copies them into `$CLAUDE_CONFIG_DIR/skills`, where Claude Code loads them as user skills. The
pack version is the one `skills-lock.json` records (26 skills, one commit); change the pack by
changing those files together.

`scripts/check-skills.sh <config>` shows what Claude Code sees in a task sandbox without calling
a model: it starts the config's agent with every Anthropic credential removed, reads the skills
from Claude Code's init event and stops at the login error. The pack config shows 26 of the 26
pack skills, the baseline 0. Both also load the 16 skills bundled with Claude Code, and both run
Claude Code 2.1.293 at `--effort max`.

## Setting up the cloud environment

Create an environment from the environment selector at claude.ai/code and fill in:

1. **Setup script:** load `scripts/cloud-setup.sh` with *Choose file*. It installs harbor 0.25.0
   with its Modal extra and the Modal CLI, and lets Modal through the session's HTTPS proxy and
   its CA bundle (`SSL_CERT_FILE`).
2. **Network access:** *Limited*, with *Allow package managers* left checked: that default list
   has PyPI for the setup script and `*.amazonaws.com`, where Modal's client sends files of 4 MiB
   or more through S3. Add these **Allowed domains**:

   ```
   api.modal.com
   api.modal2.com
   *.w.modal.host
   ```

   `api.modal.com` is Modal's API and `api.modal2.com` its failover address. Commands in a
   sandbox go to that sandbox's own `task-<id>.w.modal.host`. The agent's model API
   (`api.anthropic.com`) and the judge's host are not needed here: Modal sandboxes reach them.
3. **Environment variables**, one `NAME=value` per line. Anyone who uses the environment can read
   them. Network secrets do not fit: they attach a key to requests the VM itself makes, while the
   judge key and the agent credential are used inside Modal sandboxes, and harbor will not start
   without the Modal token in its environment.

   | Name | For |
   |---|---|
   | `MODAL_TOKEN_ID`, `MODAL_TOKEN_SECRET` | starting Modal sandboxes |
   | `OPENAI_API_KEY`, `OPENAI_API_BASE` (or `JUDGE_API_KEY`, `JUDGE_BASE_URL`) | the rubric judge, in all three lanes |
   | `JUDGE_MODEL` | `gpt-6.1-sol` when the base URL is `https://api.openai.com/v1`; leave it unset for a gateway that takes `openai/gpt-6.1-sol` |
   | `HARBOR_TELEMETRY` | optional, `0`: harbor's telemetry host is not on the allowlist |
   | `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN` | the agent under evaluation; one of the two, below. Not needed for `oracle`, `nop` or `scripts/check-skills.sh` |

   Without a `.env` file, `run.sh` takes all of these from the environment.

### The agent credential

- **API key:** `ANTHROPIC_API_KEY`, billed per token to that key's Console account.
- **Claude subscription:** `CLAUDE_CODE_OAUTH_TOKEN`, made with `claude setup-token` on a Pro or
  Max account, with `ANTHROPIC_API_KEY` unset (when both are set, harbor uses the API key unless
  `CLAUDE_FORCE_OAUTH=1`). Harbor's claude-code agent supports it. Harbor passes the token as an
  environment variable to Claude Code in every task sandbox, so for the length of a trial the
  agent, and anything it runs there (the repository's code, its tests, packages it installs), can
  read it. In the agent phase a sandbox can only reach the task's allowlist (package registries
  in qa, nothing in rf and tw) and `api.anthropic.com`, and it is deleted after the trial. Usage counts against the
  subscription's limits, which it shares with the owner's other Claude use, this cloud session
  included.

## Running

In a cloud session on this branch:

```bash
./run.sh configs/oracle.yaml qa -i qa-6905333b74f22949d97ba9cc        # reward 1.0
scripts/check-skills.sh configs/claude-opus-5-5-skills-pack.yaml      # 26 pack skills, no model call
./run.sh configs/claude-opus-5-5-skills-pack.yaml qa -i qa-6905333b74f22949d97ba9cc -k 1
./run.sh configs/claude-opus-5-5-skills-baseline.yaml qa -i qa-6905333b74f22949d97ba9cc -k 1
```

A cloud session stops a background command after 30 minutes unless `BASH_DEFAULT_TIMEOUT_MS`
(milliseconds) is set higher in the environment, and its VM can be reclaimed after a period of
inactivity. A run that was cut off continues with `harbor jobs resume -p jobs/<job>`.
