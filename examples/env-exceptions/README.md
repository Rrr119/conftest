# Environment & resource scoped exceptions

This example shows how to run **environment specific**, **resource specific**
and **expiring** exceptions while staying compatible with Conftest's existing
[`exception`](https://www.conftest.dev/exceptions/) rule structure.

## Layout

- `policy/policy.rego` — ordinary `deny_run_as_root` / `deny_privileged` rules.
- `policy/exceptions.rego` — the matching framework (environment, resource
  selectors and expiry) and the bridge to the native `exception` tally.
- `policy/exceptions_table.rego` — bundled, data-driven exception registry, so
  the example works with only `-p policy`.
- `exceptions.yaml` — the same registry as an external data file, loaded with
  `--data`.
- `env/{dev,staging,prod}.yaml` — select the environment through data.
- `workloads.yaml` — four resources used by the acceptance matrix.
- `acceptance.sh` — 27 assertions covering all acceptance criteria.

## Run the acceptance checks

```console
$ go build -o /tmp/conftest .
$ CONFTEST=/tmp/conftest bash examples/env-exceptions/acceptance.sh
```

or via bats:

```console
$ bats tests/env-exceptions/test.bats
```

## Try the three environments

```console
$ conftest test -p examples/env-exceptions/policy --env dev \
    examples/env-exceptions/workloads.yaml

$ conftest test -p examples/env-exceptions/policy --env staging \
    examples/env-exceptions/workloads.yaml

$ conftest test -p examples/env-exceptions/policy --env prod \
    examples/env-exceptions/workloads.yaml
```

`--env` is an explicit shortcut. The same environment can be supplied as data
(`-d env/dev.yaml`, setting top level `environment:`) or through the resource
labels `environment` / `env`.

## Exception entry schema

```yaml
- id: EX-PROD-MONITOR-004          # shown in output: which exception was hit
  reason: Node monitor requires privileged capabilities in prod
  ticket: SEC-1004                 # any extra fields become JSON metadata
  approved_by: security-team
  environments: [prod]             # omitted / [] / "*" => every environment
  rules: [privileged]              # deny_/violation_ suffixes; "*" => all rules
  resources:                       # OR'ed selectors; constraints inside one
    - kinds: [Deployment]          # selector are AND'ed
      names: [node-monitor]
      namespaces: [monitoring]
      labels: { tier: monitoring }
  expires_at: "2099-03-31T23:59:59Z" # RFC3339 or YYYY-MM-DD; omitted => never
  # enabled: false                 # explicit per-entry switch
```

An entry only applies when it is enabled, not expired, its environment matches
and at least one resource selector matches. `expires_at` is compared against
the current time; at (or after) the expiry instant the exception is inactive.

For deterministic tests, set `CONFTEST_EXCEPTION_NOW` to an RFC3339 timestamp
to override the clock:

```console
$ CONFTEST_EXCEPTION_NOW=2100-01-01T00:00:00Z \
    conftest test -p policy --env dev workloads.yaml   # 0 exceptions
```

## Output

The standard output identifies the exact entry that was hit:

```text
EXCP - workloads.yaml - main - [EX-PROD-MONITOR-004] Node monitor requires privileged capabilities in prod (environment=prod; expires_at=2099-03-31T23:59:59Z)
```

`--output json` additionally exposes the full entry in `exceptions[].metadata`
(`id`, `exception_id`, `rules`, `environments`, `resources`, `expires_at`,
ticket, ...).

## Compatibility

- Plain legacy `exception contains rules if { ... rules := ["x"] }` policies
  behave exactly as before; their message remains the generated exception
  query.
- Structured object entries placed directly in `exception`
  (`exception contains {"id": ..., "rules": [...]}`) are understood as well.
- An optional `exception_details` (aliases `exception_detail`,
  `exception_info`, `exception_metadata`) document can enrich legacy rule-name
  exceptions with an id/message and metadata.
