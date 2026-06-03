# shaolin-cli

The `shaolin` executable: project + module generators and runners for
[shaolin](../../docs/superpowers/specs/2026-06-03-shaolin-cli-design.md), built on Thor.

## Commands

```bash
shaolin new <app>          # scaffold a runnable app (Gemfile, boot, Dockerfile, Knative manifest, AGENTS.md)
shaolin g module <name>    # scaffold a full CQRS/ES module that boots immediately
shaolin server             # boot + serve HTTP (Falcon)
shaolin console            # boot + IRB
shaolin migrate            # boot, ensuring event-store + read-model schemas
shaolin routes             # list modules and the commands/events they expose
```

## `g module` produces the proven layout

`shaolin g module orders` generates `app/modules/orders/` with `commands/create_order.rb`,
`events/order_created.rb`, `order.rb` (aggregate), `command_handlers/`, `projections/`,
`read_models/order_record.rb`, `dto/`, `controllers/orders_controller.rb`, a read-model migration,
and `CONTRACT.md` — the same structure as `examples/demo`, which is verified to boot and serve the
full command → event → projection → query flow.

Generated modules use explicit `require_relative` for cross-references (predictable, LLM-friendly —
no autoload magic). Naming/inflection lives in `Shaolin::CLI::Naming`.

See the [design spec](../../docs/superpowers/specs/2026-06-03-shaolin-cli-design.md).
