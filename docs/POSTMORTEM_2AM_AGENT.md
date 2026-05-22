# What my AI agent did at 2am that cost $43

> A real retry-loop bug that burned $43 in OpenAI credits in 6 minutes. Why I now run a 3-LLM consent council on my own agent code before shipping.

At 2:17am, an agent running on my Mac mini M4 burned $43 in OpenAI credits in about 6 minutes.

It was not hacked. It was not doing anything impressive. It was stuck in a retry loop, politely growing its own prompt until every retry cost more than the last one.

## The bug

The agent was supposed to analyze a repo, call a tool, append the result to its working memory, then continue. If the tool failed, it retried with more context so the model could recover.

That last sentence sounds reasonable until you look at where the state mutation happened.

Here is the shape of the bug. This is simplified, but it is real Python and close to the production pattern that bit me.

```python
import asyncio
from dataclasses import dataclass, field

@dataclass
class AgentState:
    messages: list[dict[str, str]] = field(default_factory=list)

async def run_tool(name: str, args: dict) -> str:
    await asyncio.sleep(0.1)
    raise RuntimeError("tool timeout")

async def call_llm(messages: list[dict[str, str]]) -> dict:
    return {"tool": "repo_scan", "args": {"path": "."}}

async def agent_step(state: AgentState) -> None:
    for attempt in range(6):
        plan = await call_llm(state.messages)
        try:
            result = await run_tool(plan["tool"], plan["args"])
            state.messages.append({"role": "tool", "content": result})
            return
        except Exception as exc:
            # Bug 1: failure gets appended before we know retry strategy is safe.
            state.messages.append({"role": "tool", "content": f"failed: {exc}"})

            # Bug 2: the next retry includes all previous failures.
            state.messages.append({
                "role": "user",
                "content": "Retry with the full context and fix the tool call."
            })

    raise RuntimeError("agent step failed")
```

The bug is not that retries exist. Retrying tool failures is normal in agent code.

The bug is that failed attempts were added to durable agent state before the retry boundary had proven that the step was safe. Every failure became part of the next model call. The next model call produced another tool attempt. That failed too. Then the next retry included both failures, the original context, and a new instruction to recover.

The context did not just grow. It grew inside the most expensive part of the system.

A retry loop in ordinary backend code usually costs latency. A retry loop in LLM agent code can cost money every time the loop breathes.

The version on my Mac mini had more moving parts than this snippet: tool envelopes, JSON schema repair, execution traces, and a local queue. But the core mistake was the same. I mutated long-lived state inside a retry loop and then used that same state as the prompt for the next retry.

That is how a boring timeout became a small invoice.

## The math

The painful part was not one expensive call. It was the expansion.

Each retry carried the previous context plus the error trace plus the agent's own recovery instruction. The model did what I asked: it tried to reason from the full history. The billing meter also did what I asked: it charged for the full history.

Here is a rounded version of the run from 2:17am. The exact token counts varied by tool envelope and trace length, but this is the shape.

| Retry | Approx input tokens | Approx output tokens | Approx cost |
| --- | ---: | ---: | ---: |
| 1 | 48,000 | 2,100 | $2.80 |
| 2 | 71,000 | 2,300 | $4.05 |
| 3 | 102,000 | 2,600 | $5.85 |
| 4 | 139,000 | 2,900 | $8.00 |
| 5 | 186,000 | 3,200 | $10.65 |
| 6 | 207,000 | 3,400 | $11.65 |
| **Total** |  |  | **$43.00** |

This is why "just retry it" is not a harmless phrase in agent systems.

The first retry was already too large, but still survivable. By retry 4, the agent was no longer paying mostly for the task. It was paying to reread its own failed recovery attempts.

In a normal service, I would expect a six-attempt retry loop to be annoying. Maybe it ties up a worker. Maybe it delays a job. Maybe it emits noisy logs.

In an LLM agent with tool traces in context, a six-attempt retry loop can turn into a compounding cost function.

This was not a month-long cloud bill horror story. It was $43. It was small enough to laugh at and large enough to respect. More importantly, it happened while I was asleep, on a machine I intentionally run 24/7.

That is the part that changed my standards.

## Why a normal code review missed it

A normal code review looked at each piece and found reasonable code.

The retry loop had a bound: 6 attempts. Good.

The tool failures were recorded. Good.

The agent got more context after failure. Often good.

The state object was passed through the agent step instead of rebuilt every time. Also normal.

The problem did not live in any single function. It lived at the intersection of state mutation timing, context growth, tool-failure semantics, and cost ceilings.

That is the kind of bug I now care about most in agent code.

State mutation timing mattered because the failed tool result became durable before the retry completed.

Context growth mattered because durable state was used directly as model input.

Tool-failure semantics mattered because a timeout was treated as meaningful evidence for the next reasoning pass, instead of as a transient infrastructure failure.

Cost ceilings mattered because there was no hard budget around the step. The retry counter capped attempts, but it did not cap spend.

The code had a safety shape that looked correct from four local angles. It had a failure shape that only appeared when those angles overlapped.

This is why I started running my own agent code through a 3-LLM consent council before shipping changes that can spend money, call tools, write files, or run unattended.

Not because I think LLMs are magic reviewers. I do not.

Because different models tend to be suspicious in different directions.

## What each LLM caught when I ran the audit

I ran the same code through Codex, Claude, and Gemini with the same instruction: find agent-hardening risks that could cause cost, state corruption, bad tool execution, or misleading observability.

Codex went straight at the async and state semantics. It flagged that `state.messages` was both the retry input and the durable memory target. The exact issue was not a race in the thread-safety sense. It was an accumulation pattern: failed attempts were committed before the step had reached a valid terminal state. Codex also pointed out that cancellation halfway through the retry loop would leave the agent with a corrupted narrative of what happened.

Claude focused on guardrails. It suggested wrapping the whole retry operation in a cost-budget context manager and treating the budget as a first-class runtime constraint, not a logging metric. That was the missing piece. I had a retry limit, but I did not have a spend limit. Six attempts sounds bounded until each attempt is allowed to grow.

Gemini focused on observability. It noticed that the logs claimed "retry success" after the model produced a repaired tool call, before the repaired state had actually been committed. That meant the run could look healthy in logs while the state object still contained failed intermediate traces. In other words, I had logs that described intent, not truth.

That combination was useful.

The value was not that 3 LLMs are smarter than 1. That is the wrong framing. The value is that they have different biases, so they catch different things.

Codex looked like an engineer reading control flow.

Claude looked like a safety reviewer asking where the brakes were.

Gemini looked like an SRE asking whether the logs would lie at 2am.

I needed all three views because the bug itself crossed those boundaries.

## The fix

The fixed version has three changes.

First, retries run inside a cost budget. Second, state is snapshotted before the attempt and restored if the retry path mutates state but fails. Third, retry count and context size are both bounded.

Here is the same pattern with the hardening added.

```python
import asyncio
from contextlib import asynccontextmanager
from copy import deepcopy
from dataclasses import dataclass, field

@dataclass
class AgentState:
    messages: list[dict[str, str]] = field(default_factory=list)

class CostBudget:
    def __init__(self, dollars: float) -> None:
        self.limit = dollars
        self.spent = 0.0

    def charge(self, dollars: float) -> None:
        self.spent += dollars
        if self.spent > self.limit:
            raise RuntimeError(f"cost budget exceeded: ${self.spent:.2f}")

@asynccontextmanager
async def cost_budget(dollars: float):
    budget = CostBudget(dollars)
    yield budget

async def run_tool(name: str, args: dict) -> str:
    await asyncio.sleep(0.1)
    raise RuntimeError("tool timeout")

async def call_llm(messages: list[dict[str, str]], budget: CostBudget) -> dict:
    budget.charge(0.75)  # Defends against invisible retry spend.
    return {"tool": "repo_scan", "args": {"path": "."}}

async def agent_step(state: AgentState) -> None:
    max_retries = 3  # Defends against unbounded tool retry loops.
    max_context_messages = 20

    async with cost_budget(5.00) as budget:
        for attempt in range(1, max_retries + 1):
            snapshot = deepcopy(state.messages)  # State rollback point.

            try:
                prompt = state.messages[-max_context_messages:]
                plan = await call_llm(prompt, budget)
                result = await run_tool(plan["tool"], plan["args"])

                # Commit only after the tool has actually succeeded.
                state.messages.append({"role": "tool", "content": result})
                return

            except Exception as exc:
                # Reset if anything after the snapshot mutated state.
                state.messages = snapshot

                # Keep retry metadata small and outside durable tool history.
                if attempt == max_retries:
                    raise RuntimeError(f"agent step failed after {attempt} attempts") from exc

                state.messages.append({
                    "role": "system",
                    "content": f"Transient tool failure on attempt {attempt}; retry compactly."
                })
```

This code is still not a full agent runtime. It does not include token estimation, structured tool envelopes, cancellation handling, or trace IDs. But the important boundary is there.

The retry loop no longer gets to grow forever inside durable state. A failed attempt does not become history unless I explicitly decide it should. The cost budget can stop the step even if the retry counter has attempts left. The context window is trimmed before the call.

There is one more subtle change: the failure message is compact. It says what the next attempt needs to know and no more.

That matters. Agents do not need every byte of every failure to make a better next decision. In many cases, giving them the full trace makes the next decision worse and more expensive.

The main fix was not a clever algorithm. It was a boundary.

Retries are speculative. Durable state is not. Billing is real. Logs need to describe committed facts.

Once those four ideas are separated in code, the whole system gets calmer.

## When this kind of audit is worth $499

I am now selling same-day AI architecture audits for agent code. The price is $499.

That is worth it when the agent is already in production or close to it. It is worth it when the agent can spend money, call external tools, write files, open pull requests, send emails, run shell commands, or mutate customer-visible state. It is especially worth it if the agent runs while you sleep and you want it to keep doing that.

This audit is also useful when you have one developer owning the whole thing. That is my situation on clawkit, video-analyze, and openclaw. Solo velocity is real, but so is solo blind spot accumulation. A second reviewer helps. Three reviewers with different failure biases helps more.

The audit is not worth it if your prototype is less than a week old. You probably still need to move fast and break your own assumptions.

It is not worth it if the code is small enough that you could harden it yourself in less than a day. In that case, spend the day. Add cost caps, dry-run mode, trace IDs, bounded retries, tool allowlists, and state rollback. You will learn more by doing it.

It is not worth it if you cannot legally share the code. I am not interested in playing games with proprietary code boundaries, customer data, or compliance requirements. If the code cannot leave your environment, use the checklist from this post and run the review internally.

The audits I want to do are narrow and practical. I am looking for the places where agent behavior crosses into real-world impact: money, filesystem, network calls, email, user data, deployment, database writes, and long-running autonomy.

I am not going to send back a 40-page strategy memo. I am going to send back the bugs I would fix first, the guardrails I would add before sleeping, and the architectural risks I would not ship around.

If you want me to run this kind of audit on your agent code, I'm taking 3 same-day slots this week. $499. You send a GitHub link or zipped codebase, I send back a PDF audit plus a 30-minute walkthrough call by EOD next day. Three LLMs, one prioritized hardening roadmap, zero fluff. [Book a slot](https://buy.stripe.com/cNi8wR5Gj1GzbLt2wz1Fe02).

---

📹 60-second video version of this story: <YOUTUBE_LINK_AFTER_PUBLISH>

P.S. — I work a day job. This is the Mac mini side of the desk.
