# Server Update Instructions

If you encounter divergent branches error on the server, use one of these solutions:

## Solution 1: Reset to Match Remote (Recommended)

This will discard any local changes and make the server match GitHub exactly:

```bash
# Fetch the latest from remote
git fetch origin

# Reset local branch to match remote (discards local changes)
git reset --hard origin/main

# Verify you're up to date
git status
```

## Solution 2: Configure Git Pull Strategy

If you want to keep local changes and merge them:

```bash
# Set merge strategy (creates merge commits)
git config pull.rebase false

# Then pull
git pull
```

Or use rebase (cleaner history):

```bash
# Set rebase strategy (replays local commits on top)
git config pull.rebase true

# Then pull
git pull
```

## Solution 3: Force Pull (If you want remote to win)

```bash
# Fetch and reset
git fetch origin
git reset --hard origin/main
```

## Recommended Approach

Since the repository on GitHub is the source of truth, use **Solution 1** to ensure the server matches exactly what's on GitHub.

