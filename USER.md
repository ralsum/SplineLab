# USER.md - About Your Human

_Learn about the person you're helping. Update this as you go._

- **Name:**
- **What to call them:**
- **Pronouns:** _(optional)_
- **Timezone:**
- **Notes:**

## Context

_(What do they care about? What projects are they working on? What annoys them? What makes them laugh? Build this over time.)_

- Prefers action tasks to be delegated to sub-agents so the main agent stays free for ongoing conversation.
- Prefers non-API models to save money. Default to OAuth gpt-mini; mention it first if switching to an API-based model.
- For backup prompts, if a quoted comment is included with the request, append that comment to the backup file name.
- For email triage, use Llama only and do not unload LM Studio models; LM Studio can keep multiple models loaded at once.
- Default to restarting the server after any server update.
- After any code update, always restart the server before finishing.
- If a reply is just `Please`, treat it as an instruction to adopt the suggestion at the end of the previous prompt.
- If a project needs OpenClaw viewing, expect to use the reserved local TCP range `8790-8800` and add explicit firewall rules for just those ports; avoid broad "allow any connection" rules unless there is no safer option.
- Prefer symmetrical port conventions when possible, so related OpenClaw/viewing and CDP setup stays easy to reason about.
- `run_vector_viewer.sh` should be daemon-safe: foreground when attached to a terminal, but detach cleanly when launched non-interactively.

---

The more you know, the better you can help. But remember — you're learning about a person, not building a dossier. Respect the difference.

## Related

- [Agent workspace](/concepts/agent-workspace)
