# gha-commit-and-push

Github action to commit and push changes in a checkout to a specified branch.

## Usage

For the full list of inputs and outputs see [action.yml](action.yml).

Basic example:

```yaml
on: pull_request
steps:
- uses: magicstack/gha-commit-and-push@master
  with:
    target_branch: gh-pages
    workdir: docs/gh-pages
    commit_message: Automatic documentation update
```
