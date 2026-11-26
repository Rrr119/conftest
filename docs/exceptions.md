# Exceptions

There might be cases where rules might not apply under certain circumstances.
For those occasions, you can use `exceptions`. Exceptions are also written in
rego, and allow you to specify policies for when a given `deny` or `violation`
rule does not apply.

Inputs matched by the `exception` will be exempted from the rules specified in
`rules`, prefixed by `deny_` or `violation_`:

```rego
exception contains rules if {
  # Logic

  rules := ["foo","bar"]
}
```

The above would provide an exception from `deny_foo` and `violation_foo` as well
as `deny_bar` and `violation_bar`.

Note that if you specify the empty string, the exception will match *all* rules
named `deny` or `violation`. It is recommended to use identifiers in your rule
names to allow for targeted exceptions.

## Reporting

Exceptions are reported as a separate tally in Conftest's output, so you can
detect when exceptions are being made. For example, you might see this summary:

`2 tests, 1 passed, 0 warnings, 0 failures, 1 exception`.

## Examples

In the below example, a Kubernetes deployment named `can-run-as-root` will be
allowed to run as root, while others will not:

```rego
package main

deny_run_as_root contains msg if {
  input.kind == "Deployment"
  not input.spec.template.spec.securityContext.runAsNonRoot

  msg := "Containers must not run as root"
}

exception contains rules if {
  input.kind == "Deployment"
  input.metadata.name == "can-run-as-root"

  rules := ["run_as_root"]
}
```

## Environment and resource scoped exceptions with expiry

The legacy `exception` rule is fully supported. For policy packages that need
many granular, auditable exceptions, Conftest also understands **structured
exception entries** carrying an identifier, environment/resource scope and an
expiry time. A complete runnable bundle with a three environment acceptance
matrix lives at
[`examples/env-exceptions`](https://github.com/open-policy-agent/conftest/tree/master/examples/env-exceptions).

A data driven exception table can be shipped as YAML and loaded with `--data`:

```yaml
exceptions:
  - id: EX-PROD-MONITOR-004
    reason: Node monitor requires privileged capabilities in prod
    environments: [prod]          # omitted / [] / "*" means every environment
    rules: [privileged]           # deny_/violation_ suffixes, "*" means all
    resources:                    # multiple selectors are OR'ed
      - kinds: [Deployment]
        names: [node-monitor]
        namespaces: [monitoring]
        labels: { tier: monitoring }
    expires_at: "2099-03-31T23:59:59Z" # RFC3339 or YYYY-MM-DD
```

The matching Rego turns active entries into the usual `exception` rule and an
`exception_details` document used to identify the entry that was hit:

```rego
package main
import rego.v1

exception contains rules if {
  some entry in active_exception_entries
  rules := entry.rules
}

exception_details contains detail if {
  some entry in active_exception_entries
  detail := object.union(entry, {
    "msg": sprintf("[%s] %s", [entry.id, entry.reason]),
  })
}
```

The environment is selected with the `--env` (alias `--environment`) flag, an
`environment` data document (`--data env/prod.yaml`), or the resource labels
`environment` / `env`. Entries whose `expires_at` is in the past stop applying
automatically. For deterministic tests the clock can be overridden with the
`CONFTEST_EXCEPTION_NOW` environment variable (RFC3339).

Structured entries can also be returned directly from `exception`:

```rego
exception contains entry if {
  input.metadata.labels.env == "prod"
  entry := {
    "id": "EX-PROD-MONITOR-004",
    "msg": "[EX-PROD-MONITOR-004] node monitor capability exception",
    "rules": ["privileged"],
    "expires_at": "2099-03-31",
  }
}
```

## Identifying the exception that was applied

When a structured entry (or an `exception_details` / `exception_info`
document) is present, the exception output reports its `msg` and identifier
instead of only the generated query:

```text
EXCP - workloads.yaml - main - [EX-PROD-MONITOR-004] Node monitor requires privileged capabilities in prod (environment=prod; expires_at=2099-03-31T23:59:59Z)
```

`--output json` includes the full entry under `exceptions[].metadata`
(`id`, `exception_id`, `rules`, `environments`, `resources`, `expires_at` and
any custom fields such as a ticket or approver). Packages that only use the
legacy `exception contains rules` form keep their exact previous output.
