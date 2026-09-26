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

## Safe development and completion

The root Bun package defines only `bun run dev` and `bun run start`; there is no test, lint, typecheck, or build script. Use the existing Bun lockfile for dependency installation. The independent `menubar-app/` Swift package requires Swift 5.9 and macOS 13 according to its manifest; use `swift build -c release` in that directory for a compile check.

The daemon consumes real tasks and invokes agents. Use a disposable vault, explicit test configuration, and a stub agent command for runtime checks. `install.sh`, LaunchAgent commands, and the menubar installation helper modify installed applications/services; they are not harmless validation commands. Do not consume the live queue or install/start a service for an instruction-only edit.

For documentation, inspect paths and configuration references and run `git diff --check -- <changed-paths>`. For behavior changes, exercise the affected queue/state transition in isolation and distinguish a successful compile from daemon execution, installation, and real task completion. Report exact missing prerequisites while continuing independent authorized work.

Complete the authorized change through relevant verification and repair of introduced failures. Resolve routine implementation choices directly; ask only for information or decisions that materially affect the result. If blocked, name the affected action and missing prerequisite, continue independent work, and close with changed paths, checks actually run, and unverified behavior.
