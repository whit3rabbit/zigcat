# Docker Test Harness CI Guide

This guide describes how to run the Docker-based Zigcat test harness in automated environments such as GitHub Actions and Jenkins. It supplements `docker-tests/README.md`, which focuses on local execution.

## Quick Reference

- Entry point script: `./docker-tests/scripts/run-tests.sh`
- Recommended CI command: `./docker-tests/scripts/run-tests.sh --test-suites basic,protocols --platforms linux,alpine`
- Exit status: non-zero when any suite fails or infrastructure errors occur
- Logs: `docker-tests/logs/` (persist as artifact)
- Structured results: `docker-tests/results/` (persist as artifact)

## Environment Preparation

Ensure the CI runner satisfies the following prerequisites:

| Requirement | Notes |
|-------------|-------|
| Docker Engine 20.10+ | Must support the Compose plugin (`docker compose version`) |
| Docker Buildx | `docker buildx ls` should list at least one builder capable of `linux/amd64` and `linux/arm64` |
| Disk Space | Minimum 4 GB free; more for multi-platform runs |
| Memory | 8 GB recommended for parallel suites |
| Bash | The harness relies on Bash for option parsing |

Optional but useful:
- `jq` for parsing JSON summaries within the pipeline.
- Cache directories (for example `~/.cache/zig`) to reduce rebuild times.

## Running in GitHub Actions

```yaml
name: Docker Tests
on:
  push:
    branches: [ main ]
  pull_request: {}

jobs:
  docker-tests:
    runs-on: ubuntu-22.04
    steps:
      - uses: actions/checkout@v4

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Prime Zig cache
        uses: actions/cache@v4
        with:
          path: ~/.cache/zig
          key: zig-${{ runner.os }}-${{ hashFiles('build.zig', 'zig-out/**') }}

      - name: Run Docker test harness
        run: ./docker-tests/scripts/run-tests.sh --test-suites basic,protocols --platforms linux,alpine

      - name: Upload logs
        uses: actions/upload-artifact@v4
        with:
          name: docker-test-logs
          path: docker-tests/logs/

      - name: Upload results
        uses: actions/upload-artifact@v4
        with:
          name: docker-test-results
          path: docker-tests/results/
```

Key points:
- Buildx must be configured before invoking the script so that multi-architecture images can be built.
- Cache Zig artefacts whenever possible to avoid recompiling dependencies on every run.
- Always upload `logs/` and `results/` directories when the job fails to aid diagnosis.

## Running in Jenkins (Declarative Pipeline Example)

```groovy
pipeline {
  agent { label 'docker' }
  options { timestamps() }
  stages {
    stage('Checkout') {
      steps { checkout scm }
    }
    stage('Set up Buildx') {
      steps {
        sh 'docker buildx create --name ci-builder || docker buildx use ci-builder'
        sh 'docker buildx inspect --bootstrap'
      }
    }
    stage('Run Docker Tests') {
      steps {
        sh './docker-tests/scripts/run-tests.sh --test-suites basic,protocols --platforms linux,alpine'
      }
    }
  }
  post {
    always {
      archiveArtifacts artifacts: 'docker-tests/logs/**', allowEmptyArchive: true
      archiveArtifacts artifacts: 'docker-tests/results/**', allowEmptyArchive: true
    }
  }
}
```

Guidelines:
- Use an agent with Docker privileges. For Kaniko-style environments, ensure the container runtime supports `docker buildx` commands.
- Wrap the harness invocation in retry logic if the infrastructure is prone to transient Docker pulls.
- Archive logs and results even on success to keep historical data.

## Exit Codes and Failure Handling

The script returns non-zero when:
- A build, test, or cleanup step fails inside any container.
- A requested suite times out.
- Docker encounters an infrastructure error (image pull failure, network issue, etc.).

CI pipelines should fail the job on non-zero exit and surface the collected logs for investigation. When multiple suites run, the summary report in `docker-tests/results/` lists each suite with status and duration.

## Optimisation Tips

- Restrict platforms or suites for pull requests (for example, run only `linux` on PRs and the full matrix on `main`).
- Enable parallel execution with `DOCKER_TESTS_PARALLEL=1` on hosts that can support concurrent containers.
- Pre-build base images and push them to an internal registry to avoid repeated Dockerfile builds.
- Use the `--keep-artifacts` flag on failure to retain compiled binaries for reproduction steps.

## Troubleshooting in CI

- Permission errors (for example `Got permission denied while trying to connect to the Docker daemon`) indicate the runner lacks Docker privileges; adjust the CI agent configuration.
- Buildx errors often stem from missing QEMU emulation; run `docker run --rm --privileged tonistiigi/binfmt --install all` once per host when full emulation is required.
- Timeouts can be increased via `--timeout` or suite-specific configuration in the YAML file.
- Leverage `--verbose` to obtain detailed command logging when diagnosing flakiness.

For additional background, refer to historical documents in `docs-archive/docker-tests/`.
