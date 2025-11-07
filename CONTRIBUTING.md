# px - contributing

## Rules

1. **Do not introduce global shell environment modification.**  `px` must never require `source` or activate environments implicitly.
2. **Never modify `requirements.lock` directly.**  Always regenerate using:
   ```
   uv pip compile requirements.txt -o requirements.lock
   ```
3. **Do not add new required config fields** to `px.yaml` without backward compatibility.
4. **Keep the codebase POSIX-portable bash**, avoid Bash-isms that break on Mac/BSD.
5. **Validate changes** in a throwaway directory by either running the integration bench or the manual command sequence:
   ```
   ./scripts/test.bash
   ```
   or
   ```
   tmpdir=$(mktemp -d)
   cp px.bash "$tmpdir/px"
   chmod +x "$tmpdir/px"
   (cd "$tmpdir" && ./px init)
   (cd "$tmpdir" && ./px add requests)
   (cd "$tmpdir" && ./px install)
   (cd "$tmpdir" && ./px run - <<'EOF')
   print("ok")
   EOF
   ```

## Code Style
- Use **tabs** (not spaces) inside the script.
- Keep functions small, predictable, and composable.
- Avoid fancy logic: correctness and clarity > cleverness.

## Dependency Logic Touchpoints
- Always update both dependency installation (`uv pip install`/`uv pip sync`) and lockfile regeneration (`uv pip compile`).
- Ensure the lockfile hash comment stays at line 1.

## Working with the Backlog
- Treat `BACKLOG.md` as the single source of truth for outstanding work.
- When a user requests new work, add a checkbox entry before starting unless it already exists.
- Mark items as completed when delivering the change, and leave short context notes if useful.
- Reference backlog item sections in summaries when practical.

## Project Goal
`px` exists to **remove cognitive load** from Python environment usage. All contributions must preserve or improve **predictability** and **simplicity**.
