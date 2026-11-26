package main

import rego.v1

# Bundled exception registry. This is the data-driven table a policy team
# reviews through pull requests. The same structure can be shipped as
# exceptions.yaml and loaded with --data to override this table.
bundled_exceptions := [
	{
		"id": "EX-DEV-DEBUG-001",
		"reason": "Break-glass debug pod is allowed root and privileged in dev",
		"ticket": "SEC-1001",
		"approved_by": "platform-team",
		"environments": ["dev"],
		"rules": ["run_as_root", "privileged"],
		"resources": [
			{
				"kinds": ["Deployment"],
				"names": ["debug-shell"],
			},
		],
		"expires_at": "2099-12-31T23:59:59Z",
	},
	{
		"id": "EX-STG-DEBUG-ROOT-002",
		"reason": "Staging debug shell may run as root only",
		"ticket": "SEC-1002",
		"environments": ["staging"],
		"rules": ["run_as_root"],
		"resources": [
			{
				"kinds": ["Deployment"],
				"names": ["debug-shell"],
			},
		],
		"expires_at": "2099-12-31T23:59:59Z",
	},
	{
		"id": "EX-STG-LEGACY-003",
		"reason": "Legacy agent root requirement pending vendor upgrade",
		"ticket": "SEC-1003",
		"environments": ["staging"],
		"rules": ["run_as_root"],
		"resources": [
			{
				"names": ["legacy-agent"],
			},
		],
		"expires_at": "2099-06-30T23:59:59Z",
	},
	{
		"id": "EX-PROD-MONITOR-004",
		"reason": "Node monitor requires privileged capabilities in prod",
		"ticket": "SEC-1004",
		"approved_by": "security-team",
		"environments": ["prod"],
		"rules": ["privileged"],
		"resources": [
			{
				"kinds": ["Deployment"],
				"names": ["node-monitor"],
				"namespaces": ["monitoring"],
			},
		],
		"expires_at": "2099-03-31T23:59:59Z",
	},
	{
		"id": "EX-EXPIRED-BATCH-900",
		"reason": "Temporary batch root exception that has expired and must not apply",
		"ticket": "SEC-0900",
		"environments": ["dev", "staging", "prod"],
		"rules": ["run_as_root"],
		"resources": [
			{
				"names": ["batch-job"],
			},
		],
		"expires_at": "2020-01-01T00:00:00Z",
	},
]
