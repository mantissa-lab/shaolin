# Agent quickstart — build a NEW app on shaolin

The shaolin gems live in a private git repo (not RubyGems), so there's no global `shaolin` command
until you've created an app. On this machine the framework checkout is right here, so scaffold with
the local launcher at `/home/netsky/dev/labs/shaolin/bin/shaolin` + `--path` (builds against the
local gems); after that, use the app's own `bundle exec shaolin`. (Apps elsewhere install from git —
see `llms.txt`.)

## 0. Environment (required)

- Ruby **4.0.5** — prefix commands with `RBENV_VERSION=4.0.5` (the generated app pins it in
  `.ruby-version`, so inside the app it's automatic).
- PostgreSQL on a unix socket: **`DB_HOST=/tmp DB_PORT=5433`**. Start it if down:
  `pg_ctl -D /tmp/shaolin-pg -o "-p 5433 -k /tmp" -l /tmp/shaolin-pg.log start`

## 1. Create a fresh app (do this ONCE, from anywhere e.g. /home/netsky/dev/labs)

```bash
/home/netsky/dev/labs/shaolin/bin/shaolin new myapp --path /home/netsky/dev/labs/shaolin
cd myapp
RBENV_VERSION=4.0.5 bundle install
# create its dev DB:
psql -p 5433 -h /tmp -U postgres -d postgres -c "CREATE DATABASE myapp_development;"
```

`--path` makes the app's Gemfile reference the local framework gems via one `glob:` line (use this
on the machine that has the checkout; apps elsewhere use the git source instead).

## 2. Work in the app (use its own binstub)

```bash
bundle exec shaolin g module categories         # plain CRUD module (ActiveRecord model/dto/controller)
bundle exec shaolin g module orders --es        # event-sourced CQRS module (command/event/aggregate/
                                                #   handler/projection/read_model/query/dto/controller/specs)
bundle exec rspec                               # specs (green out of the box)
DB_HOST=/tmp DB_PORT=5433 DB_NAME=myapp_development PORT=9000 bundle exec shaolin server   # Falcon
bundle exec shaolin lint                        # isolation check (no cross-module reach-ins)
bundle exec shaolin describe --json             # machine-readable map of the whole app
bundle exec shaolin graph                       # module dependency graph
bundle exec shaolin projections rebuild         # rebuild read models by replaying events
```

## 3. Rules

- Each module is a self-contained folder `app/modules/<name>/`. Read its `CONTRACT.md` first.
- Never reference another module's classes directly — only via `imports`/`exports` in `module.rb`.
  `bundle exec shaolin lint` enforces this.
- Reference fields by editing the command, event, DTO, aggregate, projection, query, and the
  read-model migration together.
- Full agent guide: `/home/netsky/dev/labs/shaolin/llms.txt`. Event evolution: `docs/EVENTS.md`.

## 4. If the framework is missing something

The framework lives at `/home/netsky/dev/labs/shaolin`. If you need a framework change, write it in
your app's `BACKLOG.md` (or this repo's) under "Requests to framework maintainer" — don't hack the
framework gems directly.
