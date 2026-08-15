# Review Actionable PRs Design

## Goal

Show only pull requests that still need the current user's review attention.

## Behavior

A pull request is visible when the app knows the current GitHub login and one of these is true:

- The current user is requested as a reviewer.
- The current user has not submitted a review.
- The pull request has a commit newer than the current user's latest review.

Pull requests authored by the current user are hidden when the app knows the current login. If the login or review metadata is unavailable, the app keeps the PR visible instead of risking a false negative.

## Data Flow

Repository-scoped `gh pr list` fetches `latestReviews`, `reviewRequests`, and `commits`. `GHCore` decodes the latest review timestamp by author and the newest commit timestamp. The menu store applies the actionability predicate using the authenticated viewer login before reporting counts or rendering rows.

## Testing

Unit tests cover command fields, JSON decoding for review and commit timestamps, and the actionability predicate for requested review, unreviewed PRs, newer commits, already-reviewed PRs, and self-authored PRs.
