# Git & GitHub Guidelines

A comprehensive guide for Git commit messages, GitHub issues, pull requests, and workflow best practices.

---

## Table of Contents

- [Git Commit Messages](#git-commit-messages)
- [GitHub Issues](#github-issues)
- [Branch Naming](#branch-naming)
- [Pull Request Guidelines](#pull-request-guidelines)
- [Workflow Best Practices](#workflow-best-practices)
- [Code Review Guidelines](#code-review-guidelines)
- [Additional Tips](#additional-tips)

---

## Git Commit Messages

### Format

```
<type>(<scope>): <subject>

<body>

<footer>
```

### Types

- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation changes
- `style`: Code style changes (formatting, missing semicolons, etc.)
- `refactor`: Code refactoring (no functional changes)
- `perf`: Performance improvements
- `test`: Adding or updating tests
- `chore`: Maintenance tasks (dependencies, build config)
- `ci`: CI/CD changes
- `revert`: Reverting a previous commit

### Examples

```bash
# Good commits
feat(auth): add OAuth2 login support
fix(api): resolve timeout issue in user endpoint
docs(readme): update installation instructions
refactor(database): simplify query builder logic

# With body
feat(gitlab): add automatic backup configuration

Implements daily backups with 7-day retention.
Backups are stored in Google Cloud Storage.

Closes #123
```

### Rules

- Use imperative mood: "add" not "added" or "adds"
- Keep subject line under 50 characters
- Capitalize first letter
- No period at the end of subject
- Separate subject from body with blank line
- Wrap body at 72 characters
- Explain *what* and *why*, not *how*

---

## GitHub Issues

### Bug Report Template

```markdown
## Description
Brief description of the bug

## Steps to Reproduce
1. Go to '...'
2. Click on '...'
3. Scroll down to '...'
4. See error

## Expected Behavior
What should happen

## Actual Behavior
What actually happens

## Environment
- OS: [e.g. Ubuntu 22.04]
- Browser: [e.g. Chrome 120]
- Version: [e.g. 1.2.3]

## Screenshots
If applicable

## Additional Context
Any other relevant information
```

### Feature Request Template

```markdown
## Problem Statement
Describe the problem this feature would solve

## Proposed Solution
Describe your proposed solution

## Alternatives Considered
Other solutions you've thought about

## Additional Context
Mockups, examples, etc.
```

### Issue Naming Conventions

Be specific and descriptive. Start with action verb when possible. Include component/module name.

**Good:**
- `Fix authentication timeout on login page`
- `Add support for multi-region deployments`
- `Update Terraform module to support new GCP regions`

**Bad:**
- `Bug`
- `It doesn't work`
- `Enhancement`

### Labels

Organize with consistent labels:

- **Type:** `bug`, `feature`, `enhancement`, `documentation`
- **Priority:** `critical`, `high`, `medium`, `low`
- **Status:** `needs-triage`, `in-progress`, `blocked`, `ready-for-review`
- **Component:** `backend`, `frontend`, `infrastructure`, `ci/cd`

---

## Branch Naming

### Convention

```
<type>/<ticket-number>-<short-description>
```

### Examples

```bash
feature/PROJ-123-add-oauth-login
fix/PROJ-456-resolve-timeout-issue
hotfix/critical-security-patch
docs/update-readme
refactor/simplify-database-queries
```

### Types

- `feature/` - New features
- `fix/` or `bugfix/` - Bug fixes
- `hotfix/` - Critical production fixes
- `docs/` - Documentation
- `refactor/` - Code refactoring
- `test/` - Test additions/updates
- `chore/` - Maintenance tasks

---

## Pull Request Guidelines

### PR Title Format

```
<type>(<scope>): <description> (#issue-number)
```

**Examples:**

```
feat(auth): add OAuth2 support (#123)
fix(api): resolve timeout in user endpoint (#456)
```

### PR Description Template

```markdown
## Summary
Brief description of changes

## Changes
- Change 1
- Change 2
- Change 3

## Related Issues
Closes #123
Related to #456

## Testing
- [ ] Unit tests added/updated
- [ ] Integration tests pass
- [ ] Manual testing completed

## Screenshots
If applicable

## Checklist
- [ ] Code follows style guidelines
- [ ] Self-review completed
- [ ] Documentation updated
- [ ] No new warnings
- [ ] Tests pass locally
```

---

## Workflow Best Practices

### Daily Workflow

```bash
# Start new feature
git checkout main
git pull origin main
git checkout -b feature/PROJ-123-new-feature

# Make changes and commit frequently
git add .
git commit -m "feat(module): add initial structure"

# Keep branch updated
git fetch origin
git rebase origin/main

# Push and create PR
git push origin feature/PROJ-123-new-feature
```

### Commit Frequency

- Commit early and often (logical chunks)
- Each commit should be a working state
- Don't commit half-finished work (use `git stash` instead)

### Branching Strategy

**GitFlow (for releases):**

- `main` - Production code
- `develop` - Development branch
- `feature/*` - Feature branches
- `release/*` - Release preparation
- `hotfix/*` - Production fixes

**GitHub Flow (simpler):**

- `main` - Always deployable
- `feature/*` - All changes in feature branches
- Deploy from `main` after PR merge

---

## Code Review Guidelines

### As Reviewer

- Be constructive and respectful
- Explain *why* changes are needed
- Approve when ready, request changes when needed
- Check for tests and documentation

### Review Comments

```markdown
# Good
**Suggestion:** Consider using a constant here for better maintainability.
**Question:** Have we considered the performance impact of this approach?
**Nitpick:** Minor style issue - can fix in follow-up PR if needed.

# Bad
This is wrong.
Why did you do it this way?
```

### As Author

- Respond to all comments
- Don't take feedback personally
- Ask for clarification if needed
- Mark conversations as resolved when addressed

---

## Additional Tips

### Semantic Versioning in Tags

```bash
git tag -a v1.2.3 -m "Release version 1.2.3"
git push origin v1.2.3
```

**Version Format: MAJOR.MINOR.PATCH**

- **MAJOR:** Breaking changes
- **MINOR:** New features (backward compatible)
- **PATCH:** Bug fixes

### Useful Git Commands

```bash
# Amend last commit
git commit --amend

# Interactive rebase (clean up commits)
git rebase -i HEAD~3

# Cherry-pick specific commit
git cherry-pick <commit-hash>

# Stash changes
git stash
git stash pop

# View commit history
git log --oneline --graph --decorate

# Show changes in a commit
git show <commit-hash>

# Undo last commit (keep changes)
git reset --soft HEAD~1

# Undo last commit (discard changes)
git reset --hard HEAD~1

# Create and switch to new branch
git checkout -b feature/new-branch

# Delete local branch
git branch -d feature/old-branch

# Delete remote branch
git push origin --delete feature/old-branch

# Update local branch list
git fetch --prune

# See what changed
git diff
git diff --staged
```

### Git Aliases (Optional)

Add to `~/.gitconfig`:

```ini
[alias]
    co = checkout
    br = branch
    ci = commit
    st = status
    unstage = reset HEAD --
    last = log -1 HEAD
    visual = log --oneline --graph --decorate --all
    amend = commit --amend --no-edit
```

Usage:

```bash
git co main
git br feature/new-feature
git visual
```

---

## Quick Reference

### Commit Message Prefix Cheat Sheet

| Prefix | Use Case | Example |
|--------|----------|---------|
| `feat` | New feature | `feat(auth): add 2FA support` |
| `fix` | Bug fix | `fix(login): resolve session timeout` |
| `docs` | Documentation | `docs(api): update endpoint descriptions` |
| `style` | Formatting | `style(css): fix indentation` |
| `refactor` | Code restructure | `refactor(db): optimize queries` |
| `perf` | Performance | `perf(api): reduce response time` |
| `test` | Tests | `test(auth): add unit tests` |
| `chore` | Maintenance | `chore(deps): update dependencies` |
| `ci` | CI/CD | `ci(github): add workflow for tests` |

### Branch Types Cheat Sheet

| Type | Purpose | Example |
|------|---------|---------|
| `feature/` | New features | `feature/user-profile` |
| `fix/` | Bug fixes | `fix/login-error` |
| `hotfix/` | Critical fixes | `hotfix/security-patch` |
| `docs/` | Documentation | `docs/readme-update` |
| `refactor/` | Code refactoring | `refactor/api-structure` |
| `test/` | Testing | `test/integration-tests` |
| `chore/` | Maintenance | `chore/update-deps` |

---

## Resources

- [Conventional Commits](https://www.conventionalcommits.org/)
- [Semantic Versioning](https://semver.org/)
- [GitHub Flow](https://guides.github.com/introduction/flow/)
- [Git Flow](https://nvie.com/posts/a-successful-git-branching-model/)
- [How to Write a Git Commit Message](https://chris.beams.io/posts/git-commit/)

---

## Contributing

Feel free to suggest improvements to these guidelines by opening an issue or pull request.

---

**Last Updated:** February 2026
