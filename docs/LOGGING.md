# Logging

shaolin has one structured logger — `Shaolin::Log` — that everything routes through (HTTP requests,
the worker, the scheduler, and, when enabled, every command/query/event). Records are emitted to
pluggable **sinks**: JSON to stdout in production, human-readable in development. It's the 12-factor
analogue of Rails' `development.log` / `production.log`.

## Using it

```ruby
Shaolin::Log.info("order_placed", order_id: id, total: total)
Shaolin::Log.error("payment_failed", order_id: id, error: e.message)
```

Every record gets `ts`, `level`, `msg` plus your fields, the current **tenant** (`Shaolin::Tenant`),
and any **context** in scope. Use context to correlate a whole request/job:

```ruby
Shaolin::Log.with(run_id: run.id) do
  # every log line in here carries run_id (and request_id, if set by the HTTP layer)
end
```

## Configuration (env)

- `SHAOLIN_ENV=production` → JSON sink (`Sinks::Stdout`); otherwise pretty (`Sinks::Pretty`).
- `SHAOLIN_LOG_LEVEL` → `debug` | `info` (default) | `warn` | `error`.
- `SHAOLIN_LOG=off` → silence everything (used in tests).
- `SHAOLIN_LOG_EVERYTHING=1` → **firehose**: the command bus, query bus, and event store log every
  command (`command`), query (`query`), and domain event (`event`). Verbose by design — turn on when
  you want a full audit trail in the log stream (the event store is still your durable source of truth).

## Sinks

```ruby
Shaolin::Log.sinks = [Shaolin::Log::Sinks::Stdout.new]   # replace
Shaolin::Log.add_sink(my_sink)                            # or add (any #call(record))
```

`Sinks::Batch` is the base for DB/remote sinks — it buffers and flushes in batches off the hot path:

```ruby
bq = Shaolin::Log::Sinks::Batch.new(flush_size: 500, flush_interval: 10) do |records|
  MyBigQueryClient.insert(rows: records)   # your batched write
end
bq.start!                                  # periodic background flush
Shaolin::Log.add_sink(bq)
```

## Shipping logs to BigQuery (the easy path)

On GCP you do **not** write a BigQuery sink. Log structured JSON to stdout (the default in production),
and let the platform route it:

1. Cloud Run / GKE automatically send stdout to **Cloud Logging** (each JSON line becomes a structured
   `jsonPayload`).
2. In Cloud Logging, create a **Log Router sink** with destination **BigQuery** (a dataset). Filter to
   your service. That's it — zero application code, and queryable in BigQuery within seconds.

```bash
gcloud logging sinks create shaolin-bq \
  bigquery.googleapis.com/projects/PROJECT/datasets/DATASET \
  --log-filter='resource.type="cloud_run_revision" jsonPayload.msg!=""'
```

Use a direct `Sinks::Batch`→BigQuery sink only when you're **not** on GCP logging (e.g. another cloud,
or you need to push directly). For everything on GCP, structured stdout + a Log Router sink is simplest
and cheapest.
