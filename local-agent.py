#!/usr/bin/env python3
"""local-agent.py — Lightweight local agent using Ollama + function calling.

Usage:
    local-agent.py "List files in ~/PROJECTz/"
    local-agent.py -m mistral-nemo:latest "What's in my home directory?"
    echo "Summarize README.md" | local-agent.py -
"""

import argparse
import json
import os
import subprocess
import sys
import urllib.request

OLLAMA_URL = "http://localhost:11434/v1/chat/completions"
DEFAULT_MODEL = "qwen2.5:14b"
MAX_TURNS = 10

TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "exec",
            "description": "Execute a shell command and return stdout+stderr",
            "parameters": {
                "type": "object",
                "properties": {
                    "command": {
                        "type": "string",
                        "description": "Shell command to execute",
                    }
                },
                "required": ["command"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "read_file",
            "description": "Read the contents of a file",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Absolute file path to read",
                    }
                },
                "required": ["path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "write_file",
            "description": "Write content to a file (creates or overwrites)",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Absolute file path"},
                    "content": {"type": "string", "description": "Content to write"},
                },
                "required": ["path", "content"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "edit_file",
            "description": "Search and replace text in a file",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Absolute file path"},
                    "search": {"type": "string", "description": "Text to find"},
                    "replace": {"type": "string", "description": "Replacement text"},
                },
                "required": ["path", "search", "replace"],
            },
        },
    },
]

SYSTEM_PROMPT = (
    "You are a local file management agent. Use tools to interact with the "
    "filesystem — never guess or fabricate output. Be concise.\n"
    "Key paths: Home=${HOME}, Projects=~/PROJECTz/, "
    "Scripts=~/SCRiPTz/, Notes=~/NSTRUCTiONz/"
)


def call_llm(messages: list, model: str) -> dict:
    payload = json.dumps(
        {"model": model, "messages": messages, "tools": TOOLS, "tool_choice": "auto"}
    ).encode()
    req = urllib.request.Request(
        OLLAMA_URL,
        data=payload,
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=300) as resp:
        return json.loads(resp.read())


def execute_tool(name: str, args: dict) -> str:
    try:
        if name == "exec":
            cmd = args["command"]
            print(f"  \033[36m[exec]\033[0m {cmd}", file=sys.stderr)
            result = subprocess.run(
                cmd, shell=True, capture_output=True, text=True, timeout=30
            )
            output = result.stdout + result.stderr
            if not output.strip():
                output = f"(exit code {result.returncode})"
            if len(output) > 4000:
                output = output[:4000] + "\n... (truncated)"
            return output

        elif name == "read_file":
            path = args["path"]
            print(f"  \033[36m[read]\033[0m {path}", file=sys.stderr)
            with open(path) as f:
                content = f.read()
            if len(content) > 4000:
                content = content[:4000] + "\n... (truncated)"
            return content

        elif name == "write_file":
            path = args["path"]
            print(f"  \033[36m[write]\033[0m {path}", file=sys.stderr)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as f:
                f.write(args["content"])
            return f"Written {len(args['content'])} bytes to {path}"

        elif name == "edit_file":
            path = args["path"]
            print(f"  \033[36m[edit]\033[0m {path}", file=sys.stderr)
            with open(path) as f:
                content = f.read()
            new = content.replace(args["search"], args["replace"], 1)
            if new == content:
                return "Warning: search string not found"
            with open(path, "w") as f:
                f.write(new)
            return f"Replaced in {path}"

        else:
            return f"Unknown tool: {name}"
    except Exception as e:
        return f"Error: {e}"


def run_agent(message: str, model: str):
    messages = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": message},
    ]

    for turn in range(1, MAX_TURNS + 1):
        resp = call_llm(messages, model)
        choice = resp["choices"][0]
        msg = choice["message"]

        # Add assistant message to history
        messages.append(msg)

        tool_calls = msg.get("tool_calls") or []
        content = msg.get("content") or ""

        # No tool calls — final answer
        if not tool_calls:
            if content:
                print(content)
            return

        # Print intermediate content if any
        if content:
            print(f"\033[90m{content}\033[0m", file=sys.stderr)

        # Execute each tool call
        for tc in tool_calls:
            fn_name = tc["function"]["name"]
            fn_args = tc["function"]["arguments"]
            if isinstance(fn_args, str):
                fn_args = json.loads(fn_args)

            result = execute_tool(fn_name, fn_args)
            messages.append(
                {
                    "role": "tool",
                    "tool_call_id": tc.get("id", "call_0"),
                    "content": result,
                }
            )

        print(f"  \033[90m[turn {turn}]\033[0m", file=sys.stderr)

    print("Warning: max turns reached", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description="Local file agent via Ollama")
    parser.add_argument("message", nargs="?", default="-", help="Message (or - for stdin)")
    parser.add_argument("-m", "--model", default=DEFAULT_MODEL, help="Ollama model")
    args = parser.parse_args()

    if args.message == "-":
        message = sys.stdin.read().strip()
    else:
        message = args.message

    if not message:
        parser.print_help()
        sys.exit(1)

    run_agent(message, args.model)


if __name__ == "__main__":
    main()
