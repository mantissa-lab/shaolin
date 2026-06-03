# shaolin-http Implementation Plan


> **STATUS: ✅ COMPLETE (2026-06-03).** 5 examples incl. rack-test end-to-end (routing+params+body+command dispatch); 60 total green. Verified hanami-router 2.3.1 / rack 3.2.6. Includes core additions (ModuleContainer#keys, kernel.containers exposure). Merged to master.
> REQUIRED SUB-SKILL: superpowers:executing-plans. TDD, small files, commit per task. `cd gems/shaolin-http && bundle exec rspec`.

**Goal:** HTTP transport — controllers map requests to commands/queries; `dry-monads` results translate to HTTP; module controllers assemble into one Rack app.

**Verified (hanami-router 2.3.1 / rack 3.2.6):** dynamic routes via `Hanami::Router.new do ...; public_send(method, path, to: endpoint); end` (closure over a route list); params at `env["router.params"][:id]` (symbol keys); router is a Rack app; unmatched → 404.

**Core additions (committed on this branch):** `ModuleContainer#keys` (local component keys) + Lifecycle exposes the container map via `Shaolin::Kernel["kernel.containers"]` so the `:http` provider can enumerate module controllers at boot.

## Tasks
1. **Core: expose containers** — `ModuleContainer#keys`; Lifecycle registers `kernel.containers` (lazy) before providers start. Test in core. Commit.
2. **Request** — `Shaolin::HTTP::Request.new(env)`: `#params` (router.params + JSON body merged, symbol keys), `#[]`, `#body`. Commit.
3. **Controller base** — `routes do get "/p", :action end` DSL collecting route defs; `render_result(result, created:)` (dry-monads → HTTP table); `json(data, status:)`, `not_found`, `unprocessable(errors)` helpers. Commit.
4. **Result→HTTP table** — Success→200/201; Failure([:validation|:unprocessable,..])→422; [:not_found,..]→404; [:conflict,..]→409; else 500. Commit.
5. **Router.build(containers)** — enumerate each module container's `controllers.*`, read `class.route_set`, build Hanami::Router mapping each route to `->(env){ ctrl.public_send(action, Request.new(env)) }`; add `GET /healthz`; raise `RouteConflictError` on path+verb collision. Commit.
6. **:http provider** — `Shaolin::HTTP.register_provider!`; start { build router from `kernel.containers`; register `http.app` }. Integration test with rack-test: a synthetic module with a controller hitting command/query buses returns JSON. Commit.
7. README + green; merge.

## Definition of Done
All green (rack-test integration incl. command→event→projection→query via cqrs+AR optional, or buses stubbed); no file > ~150 lines; APIs verified.
