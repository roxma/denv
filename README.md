# denv - Auto source bash .denv.bash of your workspace

A standalone Go program that helps you automatically sources `.denv.bash` files
when you enter a directory. It finds **all** denv files in the ancestor chain
and loads the allowed ones from outer to inner, nesting shells or iterating a
colon-separated chain.

Inspired by [direnv](https://github.com/direnv/direnv), but simpler: it spawns
a new interactive bash shell instead of exporting environment diffs back to the
parent shell.

## Why?

1. **direnv** creates a new bash process, loads `.envrc`, and exports the diff
   back to the parent shell, so aliases and functions [cannot be
   exported](https://direnv.net/#faq) (see also [GitHub
   issue](https://github.com/direnv/direnv/issues/73)). **denv** simply spawns a
   new `$BASH` and lets you `cd` out to exit.
2. **direnv** loads the closest `.envrc` from the ancestor chain — parent
   environments are [unloaded when entering a subdirectory with its own
   `.envrc`](https://github.com/direnv/direnv/issues/772). **denv** finds
   **all** `.denv.bash` files in the ancestor chain and loads the allowed ones
   from outer to inner, letting you compose workspace-wide and project-level
   settings naturally.

## Install

Download the latest binary from the [releases
page](https://github.com/roxma/denv/releases) and put it in your `PATH`:

```bash
curl -fsSL https://github.com/roxma/denv/releases/latest/download/denv_linux_$(uname -m) | sudo tee /usr/local/bin/denv > /dev/null && sudo chmod +x /usr/local/bin/denv
```

Or install with Go:

```bash
go install github.com/roxma/denv@latest
```

## Usage

Add to your `.bashrc`:

```bash
# Optional: override the default config path (~/.config/denv/denv.json)
# export DENV_CONFIG="$HOME/.config/denv/denv.json"

PROMPT_COMMAND='eval "$(denv prompt)"'
```

Then:

```bash
$ mkdir foo && echo 'echo "in foo directory"' > foo/.denv.bash

$ cd foo
denv: spawn /bin/bash
denv: loading [/home/you/foo/.denv.bash]
in foo directory

$ cd ..
denv: exit [/home/you/foo/.denv.bash]
```

## Subcommands

```
$ denv
denv 1.0.0
auto source .denv.bash of your workspace

USAGE:
    denv [SUBCOMMAND]

SUBCOMMANDS:
    prompt   for bashrc: PROMPT_COMMAND='eval "$(denv prompt)"'
    allow    Grant permission to denv to load the .denv.bash
    deny     Remove the permission
    prune    Remove non-existing-file permissions
```

### `denv prompt`

Generates the shell hook code. If no shell name is given, denv auto-detects the
parent shell. Only `bash` and `sh` are supported today.

### `denv allow`

Grants permission to load **all** denv files found in the current directory and
its ancestors. Permissions are stored in `~/.config/denv/denv.json`.

Loading traverses the ancestor chain from outermost to innermost and **stops
at the first denied entry**. Allowed ancestors before that point will still
load. Running `denv allow` once approves every denv file between the current
directory and the filesystem root.

### `denv deny [path]`

Revokes permission. If `path` is omitted, denies the `.denv.bash` for the
current directory. If `path` is a directory, denies the `.denv.bash` inside it.

### `denv prune`

Removes entries pointing to deleted files/directories from the config.

## .denv tips

- `export WORKSPACE_DIR=$(readlink -f "$(dirname "${BASH_SOURCE[0]}")")` for
  `.denv.bash` to locate its directory.
- `exec bash` to reload a modified `.denv.bash`.

## Why not Bash or Python?

An early Python prototype took ~80 ms — too slow for every prompt. A Go binary
starts in under 2ms.

## Permission model

`denv allow` records the file's **ctime** (inode change time). Before loading,
denv checks it still matches. Unlike `mtime`, ctime cannot be set arbitrarily
and is available from `stat(2)` without reading the file. Any edit, `chmod`,
or `touch` changes ctime and requires re-approval.

## Notes

- Take care of background jobs before leaving an `.denv.bash` scope — denv will
  refuse to load if you have active jobs.
- The `.denv.bash` can be a **file** or a **directory**. If it's a directory,
  `$DENV_LOAD/denv.bash` is sourced instead.

## `.envrc` compatibility

When no `.denv/` or `.denv.bash` is found, denv falls back to `.envrc`.
Precedence: `.denv/` > `.denv.bash` > `.envrc`. Set `"ignore_envrc": true`
in `~/.config/denv/denv.json` to disable this.

## Acknowledgements

This project was developed with assistance from
[DeepSeek](https://chat.deepseek.com), [Kimi](https://kimi.moonshot.cn),
[kimi-cli](https://github.com/MoonshotAI/kimi-cli), and the
[opencode](https://github.com/anomalyco/opencode) tool.
