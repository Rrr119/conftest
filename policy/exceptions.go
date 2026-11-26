package policy

import (
	"context"
	"fmt"
	"sort"

	"github.com/open-policy-agent/conftest/output"
	"github.com/open-policy-agent/opa/v1/ast"
	"github.com/open-policy-agent/opa/v1/rego"
)

// exceptionDetailRules are optional Rego documents that describe which
// structured exception entry matched. They are inspected in order and every
// declared document is used, allowing policy authors to pick the name that
// fits their package.
var exceptionDetailRules = []string{
	"exception_details",
	"exception_detail",
	"exception_info",
	"exception_metadata",
}

// exceptionAliases lists document names that may carry structured exception
// entries in addition to the canonical "exception" set.
var exceptionAliases = []string{
	"exceptions",
	"exception_rules",
}

// exceptionIndex indexes structured exception entries by the (short) rule
// name they exempt. The empty string key holds entries that apply to every
// rule.
type exceptionIndex map[string][]output.Result

// lookup returns the structured exception results that apply to the given
// short rule name, including the global ("*") entries. Results are sorted to
// keep output stable across evaluations.
func (idx exceptionIndex) lookup(shortRule string) []output.Result {
	if len(idx) == 0 {
		return nil
	}

	var results []output.Result
	results = append(results, idx[shortRule]...)
	if shortRule != "" {
		results = append(results, idx[""]...)
	}
	if len(results) < 2 {
		return results
	}

	sort.SliceStable(results, func(i, j int) bool {
		if results[i].Message == results[j].Message {
			return exceptionID(results[i]) < exceptionID(results[j])
		}
		return results[i].Message < results[j].Message
	})
	return results
}

func exceptionID(result output.Result) string {
	if result.Metadata == nil {
		return ""
	}
	if id, ok := result.Metadata["exception_id"].(string); ok {
		return id
	}
	if id, ok := result.Metadata["id"].(string); ok {
		return id
	}
	return ""
}

// buildExceptionIndex evaluates the exception related documents of a namespace
// once and indexes every structured entry they contain.
//
// The lookup is purely additive: it is used to enrich the reported exception
// with the identity of the matching entry and to gate rules targeted by
// object-shaped entries. Any evaluation error is swallowed on purpose because
// the legacy per-rule exception query remains the source of truth for whether
// an exception applies and will surface real policy errors.
func (e *Engine) buildExceptionIndex(ctx context.Context, input ast.Value, namespace string, declared map[string]bool) exceptionIndex {
	idx := exceptionIndex{}

	addDocument := func(name string) {
		if !declared[name] {
			return
		}
		candidates, err := e.evalExceptionCandidates(ctx, input, fmt.Sprintf("data.%s.%s", namespace, name))
		if err != nil {
			return
		}
		idx.addCandidates(candidates)
	}

	// The canonical exception set may contain object shaped entries in
	// addition to the legacy arrays of rule name strings.
	addDocument("exception")
	for _, name := range exceptionDetailRules {
		addDocument(name)
	}
	for _, name := range exceptionAliases {
		addDocument(name)
	}

	return idx
}

func (idx exceptionIndex) addCandidates(candidates []map[string]any) {
	for _, candidate := range candidates {
		result, rules, ok := normalizeExceptionCandidate(candidate)
		if !ok {
			continue
		}
		if len(rules) == 0 {
			rules = []string{""}
		}
		for _, rule := range rules {
			idx[rule] = append(idx[rule], result)
		}
	}
}

// evalExceptionCandidates evaluates a document and returns any object values
// it contains, tolerating set, array and object shaped documents.
func (e *Engine) evalExceptionCandidates(ctx context.Context, input ast.Value, query string) ([]map[string]any, error) {
	options := []func(r *rego.Rego){
		rego.ParsedInput(input),
		rego.Query(query),
		rego.Compiler(e.Compiler()),
		rego.Store(e.Store()),
		rego.Runtime(e.Runtime()),
	}
	if e.interQueryCache != nil {
		options = append(options, rego.InterQueryBuiltinCache(e.interQueryCache))
	}

	resultSet, err := rego.New(options...).Eval(ctx)
	if err != nil {
		return nil, err
	}

	var candidates []map[string]any
	for _, result := range resultSet {
		for _, expression := range result.Expressions {
			switch value := expression.Value.(type) {
			case []any:
				for _, item := range value {
					if candidate, ok := item.(map[string]any); ok {
						candidates = append(candidates, candidate)
					}
				}
			case map[string]any:
				if isExceptionCandidate(value) {
					candidates = append(candidates, value)
					continue
				}
				// Object document keyed by identifier: use its values.
				for _, item := range value {
					if candidate, ok := item.(map[string]any); ok {
						candidates = append(candidates, candidate)
					}
				}
			}
		}
	}
	return candidates, nil
}

// isExceptionCandidate reports whether an object itself looks like a
// structured exception entry, as opposed to a map keyed by exception id.
func isExceptionCandidate(m map[string]any) bool {
	for _, key := range []string{"id", "exception_id", "exceptionId", "code", "msg", "message", "reason", "rules", "rule"} {
		if _, ok := m[key]; ok {
			return true
		}
	}
	return false
}

// normalizeExceptionCandidate converts a structured exception entry into an
// output Result and the normalized short rule names it targets.
func normalizeExceptionCandidate(candidate map[string]any) (output.Result, []string, bool) {
	id := firstString(candidate, "id", "exception_id", "exceptionId", "code")
	message := firstString(candidate, "msg", "message")
	reason := firstString(candidate, "reason", "description", "justification")
	title := firstString(candidate, "title", "name")

	if message == "" {
		switch {
		case id != "" && reason != "":
			message = fmt.Sprintf("[%s] %s", id, reason)
		case id != "" && title != "":
			message = fmt.Sprintf("[%s] %s", id, title)
		case id != "":
			message = fmt.Sprintf("[%s] exception matched", id)
		case reason != "":
			message = reason
		case title != "":
			message = fmt.Sprintf("exception: %s", title)
		default:
			// No identifying information: do not replace the legacy query
			// based message with an opaque result.
			return output.Result{}, nil, false
		}
	}

	targets := exceptionRules(candidate)

	document := make(map[string]any, len(candidate)+1)
	for key, value := range candidate {
		document[key] = value
	}
	document["msg"] = message

	result, err := output.NewResult(document)
	if err != nil {
		return output.Result{}, nil, false
	}
	if result.Metadata == nil {
		result.Metadata = map[string]any{}
	}
	if id != "" {
		if _, ok := result.Metadata["exception_id"]; !ok {
			result.Metadata["exception_id"] = id
		}
		if _, ok := result.Metadata["id"]; !ok {
			result.Metadata["id"] = id
		}
	}

	return result, targets, true
}

// exceptionRules extracts and normalizes the rule names targeted by an entry.
// "*" and empty values are normalized to the global ("") target.
func exceptionRules(candidate map[string]any) []string {
	var raw []string

	switch rules := candidate["rules"].(type) {
	case []any:
		for _, rule := range rules {
			if value, ok := rule.(string); ok {
				raw = append(raw, value)
			}
		}
	case []string:
		raw = append(raw, rules...)
	case string:
		raw = append(raw, rules)
	}

	for _, key := range []string{"rule", "target", "policy"} {
		if value, ok := candidate[key].(string); ok && value != "" {
			raw = append(raw, value)
		}
	}

	if targets, ok := candidate["targets"].([]any); ok {
		for _, target := range targets {
			if value, ok := target.(string); ok {
				raw = append(raw, value)
			}
		}
	}

	var normalized []string
	seen := map[string]bool{}
	for _, rule := range raw {
		if rule == "*" {
			rule = ""
		}
		rule = removeRulePrefix(rule)
		if seen[rule] {
			continue
		}
		seen[rule] = true
		normalized = append(normalized, rule)
	}
	return normalized
}

func firstString(m map[string]any, keys ...string) string {
	for _, key := range keys {
		if value, ok := m[key].(string); ok && value != "" {
			return value
		}
	}
	return ""
}
