/*
 * Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com).
 * Licensed under the Apache License, Version 2.0.
 */

package config

import (
	"strings"
	"testing"

	api "github.com/wso2/api-platform/gateway/gateway-controller/pkg/api/management"
)

func TestPathParamModelExpressionValidation(t *testing.T) {
	validator := NewLLMValidator()
	tests := []struct {
		name       string
		identifier string
		wantError  string
	}{
		{name: "Bedrock capture", identifier: `model/([A-Za-z0-9.:-]+)/`},
		{name: "Gemini capture", identifier: `models/([a-zA-Z0-9.\-]+)`},
		{name: "invalid regex", identifier: `([`, wantError: "valid Go regular expression"},
		{name: "missing capture", identifier: `[a-z]+`, wantError: "must contain a capture group"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			errors := validator.validateExtractionIdentifier("spec.requestModel", &api.ExtractionIdentifier{
				Location: "pathParam", Identifier: tt.identifier,
			})
			if tt.wantError == "" {
				if len(errors) != 0 {
					t.Fatalf("expected expression to pass, got %v", errors)
				}
				return
			}
			if len(errors) != 1 || !strings.Contains(errors[0].Message, tt.wantError) {
				t.Fatalf("expected error containing %q, got %v", tt.wantError, errors)
			}
		})
	}
}

func contextRoutingParams(provider string) map[string]interface{} {
	target := map[string]interface{}{"model": "routed-model"}
	if provider != "" {
		target["provider"] = provider
	}
	return map[string]interface{}{
		"routes": []interface{}{
			map[string]interface{}{"maxTokens": float64(200000), "target": target},
		},
	}
}

func TestValidateContextBasedRoutingProviderAliases(t *testing.T) {
	alias := "secondary"
	params := contextRoutingParams(alias)
	spec := &api.LLMProxyConfigData{
		AdditionalProviders: &[]api.LLMProxyAdditionalProvider{{Id: "provider-id", As: &alias}},
		GlobalPolicies: &[]api.Policy{{
			Name: contextBasedRoutingPolicyName, Version: "v0", Params: &params,
		}},
	}
	if errors := validateContextBasedRoutingPolicies(spec); len(errors) != 0 {
		t.Fatalf("expected known alias to pass, got %v", errors)
	}

	unknown := contextRoutingParams("missing-provider")
	spec.GlobalPolicies = &[]api.Policy{{Name: contextBasedRoutingPolicyName, Version: "v0", Params: &unknown}}
	errors := validateContextBasedRoutingPolicies(spec)
	if len(errors) != 1 || !strings.Contains(errors[0].Message, "unknown additional provider") {
		t.Fatalf("expected unknown-provider error, got %v", errors)
	}
}

func TestValidateContextBasedRoutingRejectsOverlappingRouter(t *testing.T) {
	params := contextRoutingParams("")
	spec := &api.LLMProxyConfigData{
		GlobalPolicies: &[]api.Policy{
			{Name: contextBasedRoutingPolicyName, Version: "v0", Params: &params},
			{Name: "model-round-robin", Version: "v1"},
		},
	}
	errors := validateContextBasedRoutingPolicies(spec)
	if len(errors) != 1 || !strings.Contains(errors[0].Message, "both select the model or provider") {
		t.Fatalf("expected conflicting-router error, got %v", errors)
	}
}

func TestValidateContextBasedRoutingAllowsModelAccessControl(t *testing.T) {
	params := contextRoutingParams("")
	spec := &api.LLMProxyConfigData{
		GlobalPolicies: &[]api.Policy{
			{Name: "model-access-control", Version: "v0"},
			{Name: contextBasedRoutingPolicyName, Version: "v0", Params: &params},
		},
	}
	if errors := validateContextBasedRoutingPolicies(spec); len(errors) != 0 {
		t.Fatalf("model access validation should compose with routing, got %v", errors)
	}
}
