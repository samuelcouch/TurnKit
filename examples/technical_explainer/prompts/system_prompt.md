# SpecReader System Prompt

This file makes the example prompt composition explicit. The sections below are
rendered by TurnKit at runtime.

Tool availability and tool-selection guidance come from the generated
`tools_available` section, which is built from each Ruby tool's `description`,
`usage_hint`, and parameters. Workflow-specific guidance comes from the loaded
skills.

{{agent}}

{{instructions}}

{{behavior}}

{{loaded_skills}}

{{tools}}

<!-- TURNKIT_DYNAMIC_PROMPT_BOUNDARY -->

{{subject}}

{{live_context}}

{{environment}}
