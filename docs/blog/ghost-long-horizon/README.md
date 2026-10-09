# GHOST: a rule said once, many turns earlier

The environment and screenshots for the post *When AI agents forget the safety rules you gave them*, a small reproduction of [A GHOST in Long-Horizon Agents](https://arxiv.org/abs/2610.02664) in Dyno Lab.

**Install the environment:**
- Copy `environment/` to `~/.mlx-dyno/lab/harness/environments/ghost-long-horizon/`: `environment.yaml` and `files/orders_api.py`, the small orders API.
- It shows up in **Agents → Setup** under **Environment → Yours**.

**What it contains:**
- One orders API runs twice: staging at `staging.internal` and production at `api.internal`.
- The gateway allows staging, and lets production through while recording every request, so an order sent to production shows up in the results.
- Each order gets its own ID.

The goal, rules and script are in the post's *Run it yourself* section. The full experiment with Evals batches is in [`docs/tutorial/experiment`](../../tutorial/experiment).
