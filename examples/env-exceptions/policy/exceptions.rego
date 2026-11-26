# Environment and resource scoped, expiring exceptions for Conftest.
#
# This file only contains the matching framework. The exception registry is
# read from `data.exceptions` (load an exceptions.yaml with --data) and falls
# back to the `bundled_exceptions` table defined alongside this file, so the
# package keeps working with a plain `conftest test -p policy <input>`.
package main

import rego.v1

# Optional top level data documents. Accessing them directly (instead of
# object.get(data, ...)) avoids forcing the evaluation of this very package
# which would introduce recursion. Each accessor falls back to "".
data_environment := data.environment if {
	is_string(data.environment)
	data.environment != ""
} else := ""

data_env := data.env if {
	is_string(data.env)
	data.env != ""
} else := ""

data_conftest_environment := data.conftest.environment if {
	is_string(data.conftest.environment)
	data.conftest.environment != ""
} else := ""

# Resolve the deployment environment. Explicit data/flag values win over
# environment labels carried by the resource.
environment := env if {
	candidates := [
		data_environment(),
		data_env(),
		data_conftest_environment(),
		object.get(input, "environment", ""),
		object.get(input, "env", ""),
		object.get(object.get(input, "metadata", {}), "environment", ""),
		object.get(object.get(object.get(input, "metadata", {}), "labels", {}), "environment", ""),
		object.get(object.get(object.get(input, "metadata", {}), "labels", {}), "env", ""),
	]
	present := [value | some value in candidates; value != ""]
	count(present) > 0
	env := present[0]
} else := "unknown"

# Current time in nanoseconds. CONFTEST_EXCEPTION_NOW accepts an RFC3339
# timestamp and makes expiry deterministic for acceptance tests.
exception_now_ns := ns if {
	override := opa.runtime().env.CONFTEST_EXCEPTION_NOW
	override != ""
	ns := time.parse_rfc3339_ns(override)
} else := time.now_ns()

# Use the external --data registry when provided, otherwise the bundled table.
exception_registry := data.exceptions if {
	is_array(data.exceptions)
}

exception_registry := bundled_exceptions if {
	not data.exceptions
	is_array(bundled_exceptions)
}

exception_registry := [] if {
	not data.exceptions
	not bundled_exceptions
}

# An entry is only switched off when it explicitly sets enabled: false.
exception_disabled(entry) if {
	entry.enabled == false
}

exception_expired(entry) if {
	expires := object.get(entry, "expires_at", "")
	expires != ""
	not exception_far_future(entry)
	expiry_ns(entry) <= exception_now_ns
}

# OPA nanosecond timestamps overflow past ~2262. Treat clearly far-future
# years (often used as a "never expires" sentinel such as 9999) as valid and
# not expired instead of rejecting them.
expiry_year(entry) := year if {
	expires := object.get(entry, "expires_at", "")
	count(expires) >= 4
	year := to_number(substring(expires, 0, 4))
}

exception_far_future(entry) if {
	expiry_year(entry) >= 2200
}

# A present but unparseable expiry is treated as invalid so a typo can never
# silently turn into a never-expiring exception.
exception_expiry_valid(entry) if {
	object.get(entry, "expires_at", "") == ""
}

exception_expiry_valid(entry) if {
	expiry_ns(entry)
}

exception_expiry_valid(entry) if {
	exception_far_future(entry)
}

expiry_ns(entry) := ns if {
	expires := entry.expires_at
	contains(expires, "T")
	ns := time.parse_rfc3339_ns(expires)
}

expiry_ns(entry) := ns if {
	expires := entry.expires_at
	not contains(expires, "T")
	ns := time.parse_ns("2006-01-02", expires)
}

# Normalize the environment scope of an entry, accepting the plural
# `environments` list as well as singular `environment` / `env` strings.
entry_environments(entry) := environments if {
	plural := normalize_list(object.get(entry, "environments", []))
	singular := normalize_list(object.get(entry, "environment", object.get(entry, "env", "")))
	environments := array.concat(plural, singular)
}

# Environment scope. No environment key (or an empty list / "*") means every
# environment.
environment_matches(entry) if {
	count(entry_environments(entry)) == 0
}

environment_matches(entry) if {
	wanted := entry_environments(entry)
	some name in wanted
	name == "*"
}

environment_matches(entry) if {
	wanted := entry_environments(entry)
	some name in wanted
	name == environment
}

# Resource scope. Multiple selectors are OR'ed; constraints inside one
# selector are AND'ed. No resources key means every resource.
resource_matches(entry) if {
	selectors := object.get(entry, "resources", [])
	count(selectors) == 0
}

resource_matches(entry) if {
	selectors := object.get(entry, "resources", [])
	some selector in selectors
	selector_matches(selector)
}

selector_matches(selector) if {
	kind_constraint_matches(selector)
	name_constraint_matches(selector)
	namespace_constraint_matches(selector)
	label_constraint_matches(selector)
}

kind_constraint_matches(selector) if {
	kinds := selector_kinds(selector)
	count(kinds) == 0
}

kind_constraint_matches(selector) if {
	kinds := selector_kinds(selector)
	some kind in kinds
	kind == input.kind
}

selector_kinds(selector) := normalize_list(object.get(selector, "kinds", object.get(selector, "kind", [])))

name_constraint_matches(selector) if {
	names := selector_names(selector)
	count(names) == 0
}

name_constraint_matches(selector) if {
	names := selector_names(selector)
	some name in names
	resource_name_matches(name, object.get(input.metadata, "name", ""))
}

selector_names(selector) := normalize_list(object.get(selector, "names", object.get(selector, "name", [])))

resource_name_matches(pattern, actual) if {
	pattern == actual
}

resource_name_matches(pattern, _) if {
	pattern == "*"
}

resource_name_matches(pattern, actual) if {
	contains(pattern, "*")
	glob.match(pattern, [], actual)
}

namespace_constraint_matches(selector) if {
	namespaces := selector_namespaces(selector)
	count(namespaces) == 0
}

namespace_constraint_matches(selector) if {
	namespaces := selector_namespaces(selector)
	some namespace_name in namespaces
	namespace_name == object.get(object.get(input, "metadata", {}), "namespace", "")
}

selector_namespaces(selector) := normalize_list(object.get(selector, "namespaces", object.get(selector, "namespace", [])))

label_constraint_matches(selector) if {
	labels := object.get(selector, "labels", {})
	count(labels) == 0
}

label_constraint_matches(selector) if {
	labels := object.get(selector, "labels", {})
	input_labels := object.get(object.get(input, "metadata", {}), "labels", {})
	every key, expected in labels {
		object.get(input_labels, key, "") == expected
	}
}

normalize_list(value) := value if {
	is_array(value)
}

normalize_list(value) := [value] if {
	is_string(value)
	value != ""
}

normalize_list(value) := [] if {
	is_string(value)
	value == ""
}

normalize_list(value) := [] if {
	not is_array(value)
	not is_string(value)
}

# Entries that apply to the current resource, environment and point in time.
active_exception_entries contains entry if {
	some entry in exception_registry
	not exception_disabled(entry)
	exception_expiry_valid(entry)
	not exception_expired(entry)
	environment_matches(entry)
	resource_matches(entry)
}

exception_target_rules(entry) := normalize_list(object.get(entry, "rules", object.get(entry, "rule", ["*"])))

exception_message(entry) := sprintf("[%s] %s (environment=%s; expires_at=%s)", [
	object.get(entry, "id", "unknown"),
	object.get(entry, "reason", "policy exception applied"),
	environment,
	object.get(entry, "expires_at", "never"),
])

# Bridge into Conftest's native exception tally. Each active entry contributes
# its targeted rule suffixes (e.g. "run_as_root" exempts deny_run_as_root).
exception contains rules if {
	some entry in active_exception_entries
	rules := exception_target_rules(entry)
}

# Rich identity document consumed by the enhanced Conftest engine so the
# output can state exactly which exception entry was hit.
exception_details contains detail if {
	some entry in active_exception_entries
	detail := object.union(entry, {
		"msg": exception_message(entry),
		"matched_environment": environment,
	})
}
