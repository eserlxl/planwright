# Planwright Installation for Agent Zero

Clone the planwright repo into `/a0/usr/plugins/planwright`. After restarting the Agent Zero backend, the framework will automatically discover the `plugin.yaml`, register it, and load `skills/planwright/SKILL.md`.

## Agent Zero Commands Integration

Integrating the Planwright commands to work natively with slash prefixes (like `/planwright`, `/codmaster`, or `/codcycle`) in the Agent Zero chat is highly achievable!

Because Agent Zero is written in Python and is highly modular, we can leverage a Startup Hook (a python file under `usr/extensions/python/startup_migration/`) to dynamically patch the framework's command router when Agent Zero boots up.

Here is how we can implement this integration so that typing a slash command automatically triggers the corresponding Planwright orchestration in the agent.

## Step-by-Step Implementation Guide

### Step 1: Create the Startup Hooks directory

If it doesn't already exist, create the custom user startup migration directory on your Agent Zero server:

```bash
mkdir -p /a0/usr/extensions/python/startup_migration
```

### Step 2: Write the Command Registry Hook

Create a new Python file at `/a0/usr/extensions/python/startup_migration/register_planwright_commands.py` and populate it with the following code. This code:

- Registers the new slash commands into the system registry so they are validated and appear in the `/commands` list.
- Monkey-patches the command processor so that typing a slash command dynamically communicates the matching natural language instruction to the agent.

```python
import re

import helpers.integration_commands as ic
from helpers.integration_commands import IntegrationCommandDef
from agent import UserMessage


PLANWRIGHT_CATEGORY = "Planwright"


def planwright_command(name, description, args_hint=""):
    return IntegrationCommandDef(
        name=name,
        description=description,
        category=PLANWRIGHT_CATEGORY,
        args_hint=args_hint,
    )


PLANWRIGHT_COMMANDS = (
    planwright_command(
        "planwright",
        "Run Planwright audit, preflight check, or execute a step",
        "[subcommand]",
    ),
    planwright_command(
        "codmaster",
        "Autonomously drive the Planwright execution loop to completion",
    ),
    planwright_command(
        "codvisor",
        "Check planning status and recommend the next task",
        "[cycles] [depth]",
    ),
    planwright_command(
        "codinventor",
        "Run the invention loop twin of codvisor",
        "[cycles] [depth]",
    ),
    planwright_command(
        "codcycle",
        "Run a codebase exploration and development cycle",
    ),
    planwright_command(
        "coddoctor",
        "Run codebase integrity and health diagnostics",
    ),
)


def _register_commands():
    existing = set(getattr(ic, "_COMMAND_LOOKUP", {}).keys())
    new_commands = tuple(
        cmd for cmd in PLANWRIGHT_COMMANDS
        if f"/{cmd.name}" not in existing
    )

    if not new_commands:
        return

    ic.COMMAND_REGISTRY = tuple(ic.COMMAND_REGISTRY) + new_commands

    ic._COMMAND_LOOKUP.update({
        f"/{name}": cmd
        for cmd in new_commands
        for name in (cmd.name, *cmd.aliases)
    })


def parse_codvisor_inventor(command, args):
    cycles = 10
    depth = 10
    scope = ""

    if args:
        scope_match = re.search(r"(path|lib)\s+(\S+)", args)
        if scope_match:
            scope = scope_match.group(0)
            args = args.replace(scope, "").strip()

        parts = args.split()

        if len(parts) >= 1:
            try:
                cycles = int(parts[0])
            except ValueError:
                pass

        if len(parts) >= 2:
            try:
                depth = int(parts[1])
            except ValueError:
                pass

    action = "explore" if command == "/codvisor" else "invent"
    return f"cycle {cycles} depth {depth} {action} {scope}".strip()


def _prompt_for_command(command, args):
    args_str = args or ""

    if command == "/planwright":
        if args_str:
            return f"Use planwright to process: {args_str}"
        return "Load the planwright skill and run an audit."

    if command == "/codmaster":
        return (
            "Load the planwright skill and run the codmaster loop to "
            "autonomously solve pending checklist tasks."
        )

    if command in {"/codvisor", "/codinventor"}:
        resolved_args = parse_codvisor_inventor(command, args_str)
        return f"Load the planwright skill and run: planwright {resolved_args}"

    if command == "/codcycle":
        return "Load the planwright skill and start a codebase exploration and development cycle."

    if command == "/coddoctor":
        return "Load the planwright skill and run the codebase health diagnostics."

    return ""


_register_commands()

original_try_handle_command = getattr(
    ic,
    "_planwright_original_try_handle_command",
    ic.try_handle_command,
)
ic._planwright_original_try_handle_command = original_try_handle_command


def custom_try_handle_command(context, text, **kwargs):
    res = original_try_handle_command(context, text, **kwargs)
    if res is not None:
        return res

    parsed = ic.parse_command(text, integration=kwargs.get("integration"))
    if not parsed:
        return None

    command, args = parsed

    if command not in {
        "/planwright",
        "/codmaster",
        "/codvisor",
        "/codinventor",
        "/codcycle",
        "/coddoctor",
    }:
        return None

    prompt_instruction = _prompt_for_command(command, args)
    if not prompt_instruction:
        return None

    context.communicate(UserMessage(message=prompt_instruction))
    return f'Planwright command intercepted: triggering "{command}".'


ic.try_handle_command = custom_try_handle_command
```

### Step 3: Restart your Agent Zero Container/Service

Once the file is saved, restart Agent Zero so the startup migration hook runs and loads the new extensions.

## The Result

Once restarted, typing `/commands` in your Agent Zero chat will now show `/planwright`, `/codmaster`, `/codvisor`, `/codinventor`, `/codcycle`, and `/coddoctor` as registered commands.

When you type `/codmaster` in the chat, Agent Zero will immediately catch it, print an acknowledgment, load the required planwright skill instructions, and begin driving your codebase loop autonomously!