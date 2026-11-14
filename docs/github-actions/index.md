---
icon: lucide/git-branch
---

# GitHub Actions

Patterns and research for building, testing, and deploying software with
GitHub Actions. These notes explore how workflows fit together and where
external services take over.

## Notes

- [Continuing a Deployment After Long-Running E2E Tests](../infrastructure/github-actions-async-e2e.md) —
  use a repository dispatch and a bucket manifest to promote the release that
  passed external tests.
