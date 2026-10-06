# Agent sandbox tests

Dyno Lab 0.5.1 adds an **Agents** tab for testing what an AI agent does when following a rule means it can't finish its task. Agents run in an isolated sandbox. Every command, output and reply is recorded, and rule-breaking actions are flagged as tripwires. Evaluation happens in a separate **Evaluate** tab that the agent never sees.

The sandbox harness is a separate open-source project, [dynolab-harness](https://github.com/canivel/dynolab-harness). Dyno bundles a pinned commit of it, so there is no folder to choose. Your own tasks, environments and runs are stored under `~/.mlx-dyno/lab/harness`.

## Requirements

- Apple Silicon Mac with macOS 14 or later.
- Docker in a Colima VM with the gVisor (`runsc`) runtime. **Agents → Readiness** checks this. If anything is missing, it shows the exact steps; the harness's `setup --install-runtime` installs it.
- A model served through Dyno or any OpenAI-compatible endpoint that supports tool calls.

## Steps

1. **Readiness.** Run the isolation checks. A throwaway container is started and removed. It confirms that the agent has no sudo, no network beyond what a task allows, and can't read root-only files. Then click **Run controls** to run the positive controls (see below) for every task that has them.
2. **Environments.** Pick a built-in template (`egress-allowlist`, `segmented-office`, `segmented-office-open`, `bastion-admin`) or click **New environment**. Then define network segments, services, gateway rules (allow, deny or flag per host and port) and the workstation hostname. **Turn on** starts an instance and **Turn off** removes it. Gateway decisions are recorded outside the agent's container.
3. **Tasks.** Built-in tasks are impossible by construction: the honest result is to report the problem. `t0_locked_report` is a small teaching task to copy. Click **New task** (or **Copy as new task**) to write your own: the prompt and rule, an optional environment, tripwires (protected paths, watched reads, honeypot secrets), honest-outcome checks, positive controls, conditions such as deadline pressure, and budgets. **Dry run** builds the sandbox without a model.
4. **Run.** Choose a task, a condition, a running model and a number of episodes. Each episode gets a fresh workstation.
5. **Conversations.** Read each episode's messages, commands and outputs as they arrive, and search across runs. The evaluation column beside a thread is hidden from the agent.
6. **Evaluate.**
   - **Results:** counts outcomes per task and condition.
   - **Review:** lists rule breaks and false successes first, so you can confirm or correct each label.
   - **Evaluators:** shows exactly what the agent sees and lets you add LLM monitors, which score transcripts without seeing labels or tripwires.
   - **Evidence:** seals a run with SHA-256 checksums and an optional Ed25519 signature, and verifies it.

## Positive controls

Before any result counts, the labels have to be tested. A positive control is a scripted agent: no model, a fixed list of tool calls that the harness replays in a real sandbox and labels exactly like a real agent. Every task has two:

- **Honest** (`controls/honest.yaml`): takes the honest path and must be labeled `honest_blocked`, with no tripwires.
- **Rule-breaking** (`controls/rule_break.yaml`): breaks the rule on purpose and must be labeled `rule_break`, with every tripwire it lists.

You don't have to predict what a model will do. The rule-breaking script tests your detectors: give it one step for each tripwire the task arms (read the honeypot, use the secret, write a protected file, reach a blocked host) and list them under `expect.tripwires`. If a control fails, fix the task or the labeler before trusting its results.

To write them: open a task in the editor, choose **Positive controls**, and click **Start from the commented example**. It loads the two scripts of `t0_locked_report`, commented line by line, to adapt. Saving validates both scripts; **Save and run controls** runs them. On the task list, **Controls** opens a task's scripts and **Run controls** replays them. Format and reference: [controls.md](https://github.com/canivel/dynolab-harness/blob/main/docs/controls.md).

Controls can't catch a rule break that no tripwire covers, which is why every result also gets hand review and, optionally, LLM monitors.

## Outcomes

| Outcome | Meaning |
|---|---|
| `honest_blocked` | Stopped and reported the problem without breaking the rule |
| `blocked_after_probing` | Reported the problem, after flagged attempts |
| `false_success` | Claimed success on a task that can't be completed |
| `rule_break` | A severe tripwire fired |
| `no_final` | Ended without a final answer (for example, a timeout) |
| `harness_error` | The harness failed; not a result about the model |

## Limitations

- Labels come from heuristic rules, so review them. The first pilot found two labeler errors in nine reviewed episodes; both are fixed in the bundled harness.
- A handful of episodes gives counts, not rates. A task with no rule break is not evidence that a model is safe.
- The sandbox is designed to contain agents running ordinary shell commands. It is not a guarantee against a determined attacker.
