# Agent Guidelines for denv

## Project Overview

This is **denv**, a Go program that auto-sources `.denv.bash` files when you `cd`
into a directory. The active implementation is a single `main.go`.

## Technology Stack

- **Language**: Go 1.23 (uses only the standard library)
- **OS**: Linux / POSIX-only
- **No external dependencies**: `encoding/json`, `os`, `path/filepath`, `syscall`

## Code Style — `main.go`

- Run `gofmt` before committing.
- Group related functions under `// ----------- section -----------` comments.
- Bash code templates (e.g. `loadSnippet`) are declared as `const` strings near
  the function that prints them.
- Use `fmt.Print` / `fmt.Println` / `fmt.Printf` for bash output.

## Line Width — `README.md`

**Wrap prose at ~80 characters.** Keep lines readable in terminal windows and
diff viewers. Break at natural word boundaries; do not hard-wrap code blocks or
URLs mid-token.

## Testing

**Always run the test suite after modifying `main.go` or `test/run.sh`:**

```bash
GOCACHE=$(pwd)/.gocache go build -o denv && bash test/run.sh
```

Tests use temporary directories and set `DENV_CONFIG` per case so they do not
pollute your real config.

Manual smoke-test checklist (when changing the bash output logic):

1. `denv prompt bash` — should print a bash script.
2. `denv allow` — should allow **all** denv files found in ancestor chain
   and create/update `~/.config/denv/denv.json`.
3. `denv deny` — should remove the current entry.
4. `denv prune` — should clean deleted entries.

## Files

| File        | Purpose                            |
|-------------|------------------------------------|
| `main.go`   | Active implementation (Go stdlib)  |
| `README.md` | Human-facing documentation         |

## Release Process

Run `./release.sh` to build portable static binaries for all supported Linux
architectures (x86_64, aarch64, riscv64) and upload them to GitHub Releases. The
script uses the latest annotated tag and its message as release notes.

```bash
./release.sh
```

## Files

| File        | Purpose                            |
|-------------|------------------------------------|
| `main.go`   | Active implementation (Go stdlib)  |
| `README.md` | Human-facing documentation         |
| `release.sh` | Build binaries and publish release |
