# Production runtime & deploy — Design Spec

**Date:** 2026-06-03
**Status:** Draft — pending review
**Parent:** [shaolin framework design](2026-06-03-shaolin-framework-design.md)
**Depends on:** [shaolin-server](2026-06-03-shaolin-server-design.md), [shaolin-activerecord](2026-06-03-shaolin-activerecord-design.md), [shaolin-cli](2026-06-03-shaolin-cli-design.md)
**Sub-project:** 9 of 10 (container-native, GCP-first deploy artifacts)

> **Packaging:** the artifacts are ERB templates emitted by `shaolin new` (delivered through
> shaolin-cli). This spec owns the **conventions and the templates**; shaolin-cli owns the
> generator plumbing. A thin `shaolin deploy:check` validator also lives here.

## 1. Purpose

Make **every generated shaolin app production-ready and container-native by default**, deployable
**GCP-first** (Cloud Run / GKE) and portable to the open-source equivalent (**Knative on k8s**)
with no vendor lock-in. No bespoke Rails-Kamal-style deploy: the unit of deployment is a container
image plus a Knative-compatible manifest.

## 2. Foundation (verified 2026-06-03)

- **Cloud Run uses the Knative Serving schema:** `apiVersion: serving.knative.dev/v1`,
  `kind: Service`. Container port via `ports.containerPort`; env via `containers[].env`; concurrency
  via `containerConcurrency`; autoscaling via `template.metadata.annotations`
  (`autoscaling.knative.dev/minScale` / `maxScale`). The same YAML runs on self-hosted Knative.
- **Ruby base image:** `ruby:4.0-slim-bookworm` (slim/glibc; **not** Alpine — C-extension gems
  `pg` and `karafka-rdkafka`/librdkafka are problematic on musl). Multi-stage build, non-root
  runtime user, pinned versions, Gemfile copied before source for layer caching.

> Exact Knative/Cloud Run YAML fields, Ruby 4.0-slim availability, and librdkafka packaging on
> bookworm confirmed at planning.

## 3. Generated artifacts (by `shaolin new`)

```
Dockerfile               # multi-stage, see §4
.dockerignore            # .git, tmp, log, spec, node_modules, etc.
bin/docker-entrypoint    # migrate (event store + read models) -> exec server  (PID 1)
deploy/service.yaml      # Knative Service (HTTP app -> Cloud Run / Knative)     §5
deploy/worker.yaml       # GKE Deployment (Kafka consumer/projection worker)     §6
deploy/cloudbuild.yaml   # optional: build -> push -> deploy                     §7
.env.example             # documents every ENV the app reads (12-factor)
```

## 4. Dockerfile (multi-stage)

- **builder** (`ruby:4.0-slim-bookworm`): apt build deps (`build-essential`, `libpq-dev`,
  librdkafka build/runtime deps), `bundle install --without development test`, precompile/bootsnap
  if used.
- **runtime** (`ruby:4.0-slim-bookworm`): apt **runtime-only** libs (`libpq5`, librdkafka runtime),
  create non-root `shaolin` user (fixed UID/GID), copy installed gems + app, `USER shaolin`.
- `ENV PORT=8080`; `EXPOSE 8080`; **exec-form** `ENTRYPOINT ["bin/docker-entrypoint"]` so the
  server is PID 1 and receives SIGTERM.
- `HEALTHCHECK` hitting `/healthz`.
- COPY order: `Gemfile`/`Gemfile.lock` → bundle → app source (cache efficiency).

## 5. HTTP app → Cloud Run / Knative (`service.yaml`)

Knative `Service` with:
- `spec.template.spec.containers[].image`, `ports.containerPort: 8080`, `env` (from `.env`; secrets
  via Secret Manager refs where supported, not literal secrets in YAML).
- `containerConcurrency` (tuned for Falcon's fiber-per-request; higher than a thread server).
- Autoscaling annotations `minScale` (avoid cold starts for latency-sensitive svcs) / `maxScale`.
- CPU/memory `resources.limits`.
- Liveness/readiness via `/healthz`.
- Falcon binds `$PORT` and graceful-stops within the Cloud Run ~10s window (shaolin-server).

## 6. Kafka worker → GKE (`worker.yaml`)

Karafka consumers are **long-running**, not request-driven → a **GKE Deployment** (not Cloud Run):
- `replicas`, container image, command `shaolin karafka server`.
- `terminationGracePeriodSeconds` ≥ server graceful timeout so SIGTERM drains in-flight messages.
- Liveness/readiness probes on a small health port; resource requests/limits.
- No Service object needed (no inbound traffic; it consumes from Kafka).
- Scales by partition count (documented), independently from the HTTP tier.

## 7. CI/CD (`cloudbuild.yaml`, optional)

`docker build` → push to Artifact Registry → `gcloud run deploy` (HTTP) and/or `kubectl apply`
(worker). Kept optional and minimal; teams may use their own CI. Image is the single source of
truth for both tiers.

## 8. Configuration & secrets (12-factor)

- Every config value via ENV, enumerated in `.env.example`.
- Secrets via **Secret Manager** (Cloud Run secret env) / k8s Secrets — **never** literal secrets
  committed in `service.yaml`.
- `DATABASE_URL`, `KAFKA_BOOTSTRAP_SERVERS`, `PORT`, `WEB_CONCURRENCY`, `RACK_ENV`/`SHAOLIN_ENV`,
  graceful timeout — standardized names.

## 9. Portability (no lock-in)

The same image + the Knative `service.yaml` run on **self-hosted Knative/k8s** unchanged; the GKE
`worker.yaml` is plain Kubernetes. GCP is the *default target*, not a dependency.

## 10. `shaolin deploy:check` (validator)

A thin command that validates before deploy: required ENV present, manifest parses against the
Knative/k8s schema, image tag pinned (not `latest`), non-root user set, exec-form entrypoint,
graceful-timeout ≥ Cloud Run window. Fails with actionable messages — catches the common foot-guns
the research flagged (Alpine C-ext breakage, shell-form entrypoint eating SIGTERM, `latest` tags).

## 11. Error handling

- Missing required ENV at boot → fail fast (shaolin-core config validation), surfaced before serve.
- `deploy:check` failures are non-zero exit with the specific violation.
- Entrypoint migration failure → abort start (don't serve against an un-migrated DB).

## 12. Testing strategy

- CI builds the image; a smoke test runs the container, asserts `/healthz` on `$PORT`, sends
  SIGTERM, asserts graceful exit within the window.
- Manifest templates validated against the Knative/k8s schema in CI.
- `deploy:check` unit tests over good/bad fixtures.
- Image-size budget check (multi-stage should land well under 500MB).

## 13. To verify during planning

- Current Knative Serving / Cloud Run YAML field set (2026) and Secret Manager env wiring syntax.
- `ruby:4.0-slim-bookworm` availability and the exact apt packages for `pg` + librdkafka
  (build vs runtime) on bookworm.
- Recommended `containerConcurrency` for Falcon on Cloud Run (fiber-per-request) — benchmark.
- Whether to ship a Helm chart for the worker tier (defer unless needed).
