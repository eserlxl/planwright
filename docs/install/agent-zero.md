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
from helpers.subagents import UserMessage

# 1. Define the custom Planwright slash commands
PLANWRIGHT_COMMANDS = (
    IntegrationCommandDef(
        "planwright",
        description="Run Planwright audit, preflight check, or execute a step",
        args_hint="[subcommand]",
    ),
    IntegrationCommandDef(
        "codmaster",
        description="Autonomously drive the execution loop to completion",
    ),
    IntegrationCommandDef(
        "codvisor",
        description="Check planning status and recommend the next task",
        args_hint="[cycles] [depth]",
    ),
    IntegrationCommandDef(
        "codinventor",
        description="Endless invention loop twin of codvisor",
        args_hint="[cycles] [depth]",
    ),
    IntegrationCommandDef(
        "codcycle",
        description="Run an endless codebase exploration and invention loop",
    ),
    IntegrationCommandDef(
        "coddoctor",
        description="Run codebase integrity and health diagnostic checks",
    ),
)

# 2. Inject them into the framework's global registry & lookup
ic.COMMAND_REGISTRY = ic.COMMAND_REGISTRY + PLANWRIGHT_COMMANDS
ic._COMMAND_LOOKUP.update({
    f"/{name}": cmd
    for cmd in PLANWRIGHT_COMMANDS
    for name in (cmd.name, *cmd.aliases)
})

# 3. Intercept and handle the commands
original_try_handle_command = ic.try_handle_command

def parse_codvisor_inventor(command, args):
    """
    Parses arguments for codvisor and codinventor.
    Defaults to 10 cycles, 10 depth.
    Peels 'path <X>' or 'lib <X>' and appends after.
    """
    cycles = 10
    depth = 10
    scope = ""
    
    if args:
        # Check for path or lib
        scope_match = re.search(r'(path|lib)\s+(\S+)', args)
        if scope_match:
            scope = scope_match.group(0)
            args = args.replace(scope, '').strip()
        
        parts = args.split()
        if len(parts) >= 1:
            try: cycles = int(parts[0])
            except ValueError: pass
        if len(parts) >= 2:
            try: depth = int(parts[1])
            except ValueError: pass

    action = "explore" if command == "/codvisor" else "invent"
    return f"cycle {cycles} depth {depth} {action} {scope}".strip()

def custom_try_handle_command(context, text, **kwargs):
    # First check if the original router handles it (e.g. /status, /clear, /settings)
    res = original_try_handle_command(context, text, **kwargs)
    if res is not None:
        return res

    # Parse the command line
    parsed = ic.parse_command(text, integration=kwargs.get("integration"))
    if not parsed:
        return None

    command, args = parsed

    # Handle custom Planwright slash commands
    if command in {"/planwright", "/codmaster", "/codvisor", "/codinventor", "/codcycle", "/coddoctor"}:
        args_str = args if args else ""
        
        # Map the slash command directly to the natural language agent instruction
        if command == "/planwright":
            prompt_instruction = f"Use planwright to process: {args_str}" if args_str else "Load the planwright skill and run an audit"
        elif command == "/codmaster":
            prompt_instruction = "Load the planwright skill and run the codmaster loop to autonomously solve pending checklist tasks."
        elif command in {"/codvisor", "/codinventor"}:
            resolved_args = parse_codvisor_inventor(command, args_str)
            prompt_instruction = f"Load the planwright skill and run: planwright {resolved_args}"
        elif command == "/codcycle":
            prompt_instruction = "Load the planwright skill and start a codebase exploration and development cycle."
        elif command == "/coddoctor":
            prompt_instruction = "Load the planwright skill and run the codebase health diagnostics."
        else:
            prompt_instruction = ""
            
        if prompt_instruction:
            # Dynamically inject this instruction directly into the agent's active session
            # and trigger execution, providing a seamless chat flow!
            context.communicate(UserMessage(prompt_instruction))
            return f"🤖 **Planwright Command Intercepted:** Triggering *\"{command}\"* flow..."

    return None

# Bind the custom handler
ic.try_handle_command = custom_try_handle_command
```

### Step 3: Restart your Agent Zero Container/Service

Once the file is saved, restart Agent Zero so the startup migration hook runs and loads the new extensions.

## The Result

Once restarted, typing `/commands` in your Agent Zero chat will now show `/planwright`, `/codmaster`, `/codvisor`, `/codinventor`, `/codcycle`, and `/coddoctor` as registered commands.

When you type `/codmaster` in the chat, Agent Zero will immediately catch it, print an acknowledgment, load the required planwright skill instructions, and begin driving your codebase loop autonomously!