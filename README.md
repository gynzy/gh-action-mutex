# gh-action-mutex

A simple locking/unlocking mechanism to provide mutual exclusion in Github Actions

## Getting started

To prevent concurrent access to a job:

```yaml
jobs:
  run_in_mutex:
    runs-on: ubuntu-latest
    name: Simple mutex test
    steps:
      - uses: actions/checkout@v3
      - name: Set up mutex
        uses: ben-z/gh-action-mutex@v1.0.0-alpha.10
      - run: |
          echo "I am protected!"
          sleep 5
```

By default, the `gh-mutex` branch in the current repo is used to store the state of locks.

To have multiple mutexes, simply specify the `branch` argument in the workflow config:

```yaml
jobs:
  two_clients_test_client_1:
    runs-on: ubuntu-latest
    name: Two clients test (client 1)
    needs: [simple_test]
    steps:
      - uses: actions/checkout@v3
      - name: Set up mutex
        uses: ben-z/gh-action-mutex@v1.0.0-alpha.10
        with:
          branch: another-mutex
      - run: |
          echo "I am protected by the 'another-mutex' mutex!"
          sleep 5
```

### Timeout and Cleanup

You can specify a timeout for how long to wait for the mutex before giving up:

```yaml
jobs:
  run_with_timeout:
    runs-on: ubuntu-latest
    name: Mutex with timeout
    steps:
      - uses: actions/checkout@v3
      - name: Set up mutex
        uses: ben-z/gh-action-mutex@v1.0.0-alpha.10
        with:
          timeout: 60  # Wait for 60 seconds before timing out and giving up
      - run: |
          echo "I am protected!"
          sleep 5
```

If the timeout is reached, the action will fail by default.

More options such as using a different repo to store the mutex (which allows sharing a mutex between jobs from arbitrary repos) or using different access tokens can be found in [action.yml](./action.yml).

### GitHub Enterprise Server

It might be necessary to adjust the GitHub Server URL in case you are using a GitHub Enterprise Server. You can adjust the server URL by providing `github_server` input to the action. Please make sure to not include the `https://`.

## Motivation

GitHub Action has the [concurrency](https://docs.github.com/en/actions/using-jobs/using-concurrency) option for preventing running multiple jobs concurrently. However, it has a queue of length 1. When multiple jobs with the same concurrency group get queued, only the currently running job and the latest queued job are kept. Other jobs are simply cancelled. There's more discussion [here](https://github.com/github/feedback/discussions/5435) and it appears that GitHub does not want to add the requested `cancel-pending` feature any time soon (as of 2022-03-26). This GitHub action solves that issue.

## Implementation Details

Mutexes are implemented using simple [spinlocks](https://en.wikipedia.org/wiki/Spinlock). The [test-and-set](https://en.wikipedia.org/wiki/Test-and-set) functionality is provided by Git, where a `git push` can only succeed if the commit to be pushed is a fast-forward of what's on the remote.

## Developing Locally

1. Install [act](https://github.com/nektos/act)
1. Populate `.github-token` with a personal access token with the `repo` permision.
1. `act --rebuild -v -s GITHUB_TOKEN=$(cat .github-token)`

## Inspirations

- [actions/checkout](https://github.com/actions/checkout) for the authentication logic using `GITHUB_TOKEN`.

