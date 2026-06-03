# shaolin demo

A minimal [shaolin](../../README.md) app: one `users` module as a CQRS/ES modular monolith over
PostgreSQL, served by Falcon.

## Run

```bash
# Postgres must be reachable (see config/boot.rb DATABASE; defaults to the dev cluster).
bundle exec ruby examples/demo/verify.rb     # boots + drives the full flow via Rack::Test
PORT=9292 bundle exec ruby examples/demo/bin/server   # serve with Falcon, then curl it
```

```bash
curl -X POST localhost:9292/users -H 'content-type: application/json' \
     -d '{"name":"Bruce Lee","email":"bruce@shaolin.dev"}'
# 201 Created, Location: /users/<uuid>
curl localhost:9292/users/<uuid>
# {"id":"<uuid>","name":"Bruce Lee","email":"bruce@shaolin.dev"}
```

## What happens

`POST /users` → DTO validation → `RegisterUser` command → `User` aggregate emits `UserRegistered`
→ event persisted in the Postgres event store → `UsersProjection` updates the `users_read` read
model. `GET /users/:id` queries that read model. Write and read paths are fully separated (CQRS),
and state is event-sourced.

This example is the reference the `shaolin g module` generator mirrors.
