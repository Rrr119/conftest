package main

import rego.v1

past_entry := {
	"id": "OLD",
	"expires_at": "2000-01-01T00:00:00Z",
}

future_entry := {
	"id": "NEW",
	"expires_at": "2099-01-01T00:00:00Z",
}

test_detects_expired_timestamp if {
	exception_expired(past_entry)
	not exception_expired(future_entry)
}

test_supports_date_only_expiry if {
	exception_expired({"expires_at": "2000-01-01"})
	not exception_expired({"expires_at": "2099-01-01"})
}

test_environment_scope if {
	entry := {"environments": ["dev"]}
	environment_matches(entry) with data.main.environment as "dev"
	not environment_matches(entry) with data.main.environment as "prod"
}

test_missing_environment_scope_matches_every_env if {
	environment_matches({}) with data.main.environment as "prod"
}

test_singular_environment_scope if {
	environment_matches({"environment": "staging"}) with data.main.environment as "staging"
	not environment_matches({"environment": "staging"}) with data.main.environment as "prod"
}

test_resource_selector_scope if {
	entry := {"resources": [{"kinds": ["Deployment"], "names": ["debug-shell"]}]}

	matching_input := {
		"kind": "Deployment",
		"metadata": {"name": "debug-shell"},
	}
	other_name_input := {
		"kind": "Deployment",
		"metadata": {"name": "batch-job"},
	}
	wrong_kind_input := {
		"kind": "Service",
		"metadata": {"name": "debug-shell"},
	}

	resource_matches(entry) with input as matching_input
	not resource_matches(entry) with input as other_name_input
	not resource_matches(entry) with input as wrong_kind_input
}

test_label_selector_scope if {
	entry := {"resources": [{"labels": {"tier": "monitoring"}}]}
	matching := {"metadata": {"labels": {"tier": "monitoring"}}}
	not_matching := {"metadata": {"labels": {"tier": "other"}}}

	resource_matches(entry) with input as matching
	not resource_matches(entry) with input as not_matching
}

test_disabled_entry_does_not_apply if {
	exception_disabled({"enabled": false})
	not exception_disabled({"enabled": true})
	not exception_disabled({})
}

test_active_entries_apply_full_scope if {
	table := [{
		"id": "EX-T",
		"environments": ["dev"],
		"rules": ["run_as_root"],
		"resources": [{"names": ["debug-shell"]}],
		"expires_at": "2099-01-01T00:00:00Z",
	}]
	input_doc := {
		"kind": "Deployment",
		"metadata": {"name": "debug-shell"},
	}

	active := active_exception_entries
		with data.main.exception_registry as table
		with data.main.environment as "dev"
		with input as input_doc

	count(active) == 1
}

test_expired_entries_are_not_active if {
	table := [{
		"id": "EX-OLD",
		"rules": ["run_as_root"],
		"expires_at": "2000-01-01",
	}]

	active := active_exception_entries
		with data.main.exception_registry as table
		with data.main.environment as "dev"
		with input as {"kind": "Deployment", "metadata": {"name": "x"}}

	count(active) == 0
}

test_invalid_expiry_is_not_active if {
	not exception_expiry_valid({"expires_at": "not-a-date"})

	table := [{
		"id": "EX-BAD-DATE",
		"rules": ["run_as_root"],
		"expires_at": "not-a-date",
	}]

	active := active_exception_entries
		with data.main.exception_registry as table
		with data.main.environment as "dev"
		with input as {"kind": "Deployment", "metadata": {"name": "x"}}

	count(active) == 0
}

test_far_future_sentinel_stays_active if {
	exception_expiry_valid({"expires_at": "9999-12-31T23:59:59Z"})
	not exception_expired({"expires_at": "9999-12-31T23:59:59Z"})

	table := [{
		"id": "EX-FAR",
		"rules": ["run_as_root"],
		"expires_at": "9999-12-31",
	}]

	active := active_exception_entries
		with data.main.exception_registry as table
		with data.main.environment as "dev"
		with input as {"kind": "Deployment", "metadata": {"name": "x"}}

	count(active) == 1
}
