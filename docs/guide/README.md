# shaolin documentation

shaolin is a standalone, modular CQRS/Event-Sourcing framework for Ruby, built as a set of composable, isolated gems. It is designed to be LLM-friendly and production-grade, spanning core kernel, DTO/validation, CQRS/ES, HTTP, jobs, messaging, and LLM tooling.

## Start here

- [Getting started](getting-started.md) — install, bootstrap, and run your first app
- [Modules & isolation](modules.md) — how modules are composed and kept isolated
- [Configuration reference](configuration.md) — all ENV vars and provider options
- [Best practices](best-practices.md) — recommended patterns and conventions

## Core concepts

- [Core: kernel, providers, lifecycle, utilities](core.md) — the kernel, dependency providers, app lifecycle, and shared utilities
- [DTO & validation](dto.md) — typed data objects and validation
- [CQRS & Event Sourcing](cqrs.md) — commands, queries, aggregates, and events

## Layers

- [ActiveRecord: event store, read models, migrations, replica](activerecord.md) — persistence for event store and read models
- [HTTP: controllers, routes, request/response, auth](http.md) — the HTTP layer
- [Server: Falcon/Puma, timeouts, graceful shutdown](server.md) — running the web server
- [Jobs: outbox, reactors, worker, scheduler](jobs.md) — background processing and the outbox
- [Messaging: integration-event ports](messaging.md) — integration-event ports and contracts
- [RabbitMQ adapter](rabbitmq.md) — RabbitMQ messaging adapter
- [Redis: cache, store, broker](redis.md) — Redis-backed cache, store, and broker
- [LLM: chat, tools, reasoning, structured output, audio, realtime](llm.md) — the LLM layer
- [Harness & Conversation](harness.md) — the LLM harness and conversation model

## Operating in production

- [Observability: logging, metrics, health, context](observability.md) — logging, metrics, health checks, and context
- [Production & reliability under load](production.md) — reliability and behavior under load
- [Deploy (Docker / Cloud Run / Knative)](deploy.md) — deployment targets and recipes
- [Testing](testing.md) — testing strategies and helpers

## Reference

- [CLI reference](cli.md) — command-line interface
- [Configuration reference](configuration.md) — all ENV vars and provider options

---

Note: `docs/superpowers/specs/` are historical pre-build design docs. This guide together with [../GUIDE.md](../GUIDE.md) and [../../llms.txt](../../llms.txt) are the current source of truth.
