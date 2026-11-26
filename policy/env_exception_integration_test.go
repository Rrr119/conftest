package policy_test

import (
	"context"
	"testing"

	"github.com/open-policy-agent/conftest/output"
	"github.com/open-policy-agent/conftest/parser"
	"github.com/open-policy-agent/conftest/policy"
	"github.com/open-policy-agent/opa/v1/ast"
)

func loadScopedExceptionEngine(t *testing.T) *policy.Engine {
	t.Helper()

	engine, err := policy.Load([]string{"../examples/env-exceptions/policy"}, policy.CompilerOptions{
		Capabilities: ast.CapabilitiesForThisVersion(),
		RegoVersion:  "v1",
	})
	if err != nil {
		t.Fatalf("loading policies: %v", err)
	}
	return engine
}

func scopedExceptionResult(t *testing.T, engine *policy.Engine, env string) output.CheckResult {
	t.Helper()

	if err := engine.SetEnvironment(env); err != nil {
		t.Fatalf("setting environment %q: %v", env, err)
	}

	configs, err := parser.ParseConfigurations([]string{"../examples/env-exceptions/workloads.yaml"})
	if err != nil {
		t.Fatalf("parsing configs: %v", err)
	}

	results, err := engine.Check(context.Background(), configs, "main")
	if err != nil {
		t.Fatalf("checking policies: %v", err)
	}
	if len(results) != 1 {
		t.Fatalf("expected a single aggregated result, got %d", len(results))
	}
	return results[0]
}

func scopedExceptionIDs(result output.CheckResult) []string {
	var ids []string
	for _, exception := range result.Exceptions {
		if id, ok := exception.Metadata["id"].(string); ok {
			ids = append(ids, id)
		}
	}
	return ids
}

func scopedExceptionContainsID(ids []string, wanted string) bool {
	for _, id := range ids {
		if id == wanted {
			return true
		}
	}
	return false
}

// TestEnvironmentScopedExceptionMatrix verifies the three environment
// acceptance matrix, expiry exclusion and identifiable output.
func TestEnvironmentScopedExceptionMatrix(t *testing.T) {
	engine := loadScopedExceptionEngine(t)

	tests := []struct {
		env                string
		expectedFailures   int
		expectedExceptions int
		expectedIDs        []string
		unexpectedIDs      []string
	}{
		{
			env:                "dev",
			expectedFailures:   3,
			expectedExceptions: 2,
			expectedIDs:        []string{"EX-DEV-DEBUG-001"},
			unexpectedIDs: []string{
				"EX-STG-DEBUG-ROOT-002",
				"EX-STG-LEGACY-003",
				"EX-PROD-MONITOR-004",
				"EX-EXPIRED-BATCH-900",
			},
		},
		{
			env:                "staging",
			expectedFailures:   3,
			expectedExceptions: 2,
			expectedIDs: []string{
				"EX-STG-DEBUG-ROOT-002",
				"EX-STG-LEGACY-003",
			},
			unexpectedIDs: []string{
				"EX-DEV-DEBUG-001",
				"EX-PROD-MONITOR-004",
				"EX-EXPIRED-BATCH-900",
			},
		},
		{
			env:                "prod",
			expectedFailures:   4,
			expectedExceptions: 1,
			expectedIDs:        []string{"EX-PROD-MONITOR-004"},
			unexpectedIDs: []string{
				"EX-DEV-DEBUG-001",
				"EX-STG-DEBUG-ROOT-002",
				"EX-STG-LEGACY-003",
				"EX-EXPIRED-BATCH-900",
			},
		},
	}

	for _, tc := range tests {
		t.Run(tc.env, func(t *testing.T) {
			result := scopedExceptionResult(t, engine, tc.env)

			if len(result.Failures) != tc.expectedFailures {
				t.Errorf("%s: expected %d failures, got %d: %+v", tc.env, tc.expectedFailures, len(result.Failures), result.Failures)
			}
			if len(result.Exceptions) != tc.expectedExceptions {
				t.Errorf("%s: expected %d exceptions, got %d", tc.env, tc.expectedExceptions, len(result.Exceptions))
			}

			ids := scopedExceptionIDs(result)
			for _, wanted := range tc.expectedIDs {
				if !scopedExceptionContainsID(ids, wanted) {
					t.Errorf("%s: expected exception %q in %v", tc.env, wanted, ids)
				}
			}
			for _, unwanted := range tc.unexpectedIDs {
				if scopedExceptionContainsID(ids, unwanted) {
					t.Errorf("%s: exception %q should not apply, found in %v", tc.env, unwanted, ids)
				}
			}

			for _, exception := range result.Exceptions {
				if exception.Message == "" {
					t.Errorf("%s: exception is missing an identifying message", tc.env)
				}
				if exception.Metadata["expires_at"] == nil {
					t.Errorf("%s: exception metadata is missing expires_at: %+v", tc.env, exception.Metadata)
				}
			}
		})
	}
}
