# AGENTS.md

Instructions for AI coding agents working in this repository.

## Repo Map

- `daemon.ts` is the Bun daemon entry point for vault task processing.
- `config.example.json` documents runtime configuration shape.
- `install.sh` installs the daemon/LaunchAgent workflow documented in the README.
- `menubar-app/` contains the Swift Package menubar companion and its build script.
- `package.json` defines Bun start/dev scripts.

## Commands

- `bun run start` starts the daemon.
- `bun run dev` starts the daemon in watch mode.
- `./install.sh` runs the installer flow documented in the README.
- `cd menubar-app && swift build` builds the menubar app package.

## Working Rules

- Treat vault paths, task lifecycle states, and LaunchAgent behavior as user-data-sensitive surfaces.
- Do not hard-code personal paths beyond documented defaults without making them configurable.
- Keep installer changes reflected in README setup instructions.
- Avoid broad filesystem operations in code changes; prefer explicit path handling and dry-run style checks where practical.
- Start from `git status --short` and preserve unrelated user changes.
