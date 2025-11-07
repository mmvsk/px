# px: Run Python code with dependencies

Python is great until you need dependencies.  
Then suddenly there are 6 different tools, 9 blog posts arguing about them, and 3 ways to “activate” something.

`px` makes Python behave like a normal language:

```
px install
px run script.py
```

No venv activation. No global installs. No project restructuring.  
Just run the code with the correct dependencies.


## Why this exists

The moment a Python script needs a library, the workflow stops being obvious.

- `pip install` into the system? Breaks everything.
- `virtualenv` vs `venv`? Depends who you ask.
- `pyenv`? Maybe.
- Poetry / Rye / Hatch? Entire ecosystem buy-ins.
- Tutorials disagree with each other.
- Everyone has *opinions*, not solutions.

This should not be complicated.

`px` keeps the normal Python workflow (`requirements.txt`) and just removes the friction.


## What it does

- Creates a **project-local** `.venv/`
- Syncs dependencies from `requirements.txt` using a lockfile
- Runs scripts and commands *inside the environment* **without activation**
- Doesn’t change how you structure your code
- Doesn’t introduce a new packaging format

```
px install          # create venv + install dependencies
px add requests     # add a dependency (lockfile updates)
px run main.py      # runs inside .venv automatically
px exec pytest      # run any command inside the env
```

No ceremony.  
No remembering incantations.  
No “oh right, I forgot to activate the env”.

`px.yaml` is optional. Use it only if you want scripts, project defaults, or Python version pinning.


## Optional: Project Setup & Named Scripts

If you want named commands or a default “start” script, you can initialize a project:

```
px init
```

This creates:

```
px.yaml
requirements.txt
```

Add scripts to `px.yaml`:

```yaml
version: 1
scripts:
  serve: "python -m http.server"
  start: "python main.py"   # this becomes: px start
```

Now you can run them without remembering commands:

```
px run serve
px run start
px start        # shorthand for the 'start' script
```

This is optional. If you never create `px.yaml`, `px` still works exactly the same.


## Endorsements ;)

> “px is what pip + venv should have evolved into in 2015.”
> — Grok 4

> “If you already use requirements.txt and don’t want Poetry brain, px is basically ideal”
> — GPT-5

> “This is legitimately well-crafted. The code is clean, the design decisions are sound.”
> — Claude Sonnet 4.5

> “A lightweight orchestration layer that fixes Python’s worst ergonomic flaw without replacing its ecosystem.”
> — Gemini Flash 2.5


## Commands

| Command                   | Description                                                         |
| ------------------------- | ------------------------------------------------------------------- |
| `px install`              | Ensure correct Python version, create `.venv`, install dependencies |
| `px add <pkg>`            | Add a dependency to `requirements.txt` and update the lockfile      |
| `px rm <pkg>`             | Remove a dependency cleanly                                         |
| `px run <file or script>` | Run inside the venv (no activation required)                        |
| `px exec <command>`       | Run arbitrary commands inside the venv                              |
| `px init [dir]`           | Create a new project (optional)                                     |
| `px doctor`               | Show project & environment status                                   |

Scripts can be defined in `px.yaml` and run using `px run <name>`.


## Installation

```sh
make            # builds px into dist/
make install    # installs to ~/.local/bin/px (or set INSTALL_DIR)
```

Once `px` is on your PATH, `cd` into any project and run `px install` — it works immediately and you can layer on `px.yaml` later if you need more precision.

Or run directly:

```sh
bash px.bash run script.py
```

## Requirements

- `python3` (required)
- `pip` (required)
- `uv` (required - install via `pipx install uv` or see https://github.com/astral-sh/uv)
- `pyenv` (optional - for automatic Python version installation)


## Philosophy

- Local environments only
- Zero-config by default; px.yaml stays optional and additive
- Explicit installs (px never auto-installs behind your back)
- Reproducible dependency resolution via lockfile
- No hidden state, no global changes, no surprises


## Contributing

```sh
bash px.bash        # run px directly from the repo
./scripts/test.bash # run integration tests
```


## License

MIT
