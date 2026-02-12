# Git Hooks for PayBack

This directory contains Git hooks that help maintain code quality by running automated checks before commits.

## Available Hooks

### pre-commit

Runs unit tests before allowing a commit. This ensures that all tests pass before code is committed to the repository.

**What it does:**

- Runs the PayBackTests suite
- Aborts the commit if any tests fail
- Shows test results summary

## Installation

To enable these hooks, run the following command from the repository root:

```bash
git config core.hooksPath .githooks
```

Or use the setup script:

```bash
./scripts/setup-git-hooks.sh
```

## Bypassing Hooks

If you need to commit without running the hooks (not recommended), use:

```bash
git commit --no-verify
```

## Requirements

- Xcode with command line tools installed
- iOS Simulator configured
- PayBack project properly set up

## Troubleshooting

### Hook not running

- Verify hooks are installed: `git config core.hooksPath`
- Check hook is executable: `ls -la .githooks/pre-commit`
- Make it executable: `chmod +x .githooks/pre-commit`

### Tests taking too long

- Consider running only fast unit tests in the hook
- Use `--no-verify` for work-in-progress commits
- Run full test suite before pushing instead

### Simulator not available

- Open Xcode and ensure simulators are installed
- Run `xcrun simctl list` to see available simulators
- Update the simulator name in the hook if needed
