/*
 * Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com).
 * Licensed under the Apache License, Version 2.0.
 */

package utils

import (
	"strings"
	"testing"

	api "github.com/wso2/api-platform/gateway/gateway-controller/pkg/api/management"
	"github.com/wso2/api-platform/gateway/gateway-controller/pkg/models"
)

func TestSelectedProviderExecutionConditionForBodyPhase(t *testing.T) {
	headerCondition := selectedProviderExecutionConditionForPhase("secondary", false, false)
	if strings.Contains(headerCondition, "request_body") {
		t.Fatalf("header routing condition unexpectedly contains request body phase: %s", headerCondition)
	}
	bodyCondition := selectedProviderExecutionConditionForPhase("secondary", false, true)
	if !strings.Contains(bodyCondition, "processing.phase == 'request_body'") || !strings.Contains(bodyCondition, "secondary") {
		t.Fatalf("body routing condition is incomplete: %s", bodyCondition)
	}
}

func TestGlobalContextRoutingReceivesModelSystemParameters(t *testing.T) {
	params := map[string]interface{}{"routes": []interface{}{}}
	policies := []api.Policy{{Name: "context-based-routing", Version: "v0", Params: &params}}
	template := &models.StoredLLMProviderTemplate{
		Configuration: api.LLMProviderTemplate{
			Spec: api.LLMProviderTemplateData{
				RequestModel:  &api.ExtractionIdentifier{Location: "payload", Identifier: "$.model"},
				ResponseModel: &api.ExtractionIdentifier{Location: "payload", Identifier: "$.modelVersion"},
			},
		},
	}
	result := globalLLMPoliciesWithTemplateParams(&policies, template)
	requestModel, ok := (*result[0].Params)["requestModel"].(map[string]interface{})
	if !ok || requestModel["identifier"] != "$.model" {
		t.Fatalf("requestModel system parameter was not injected: %#v", result[0].Params)
	}
	if _, exists := (*result[0].Params)["responseModel"]; exists {
		t.Fatalf("unused responseModel system parameter was injected: %#v", result[0].Params)
	}
}

func TestLLMProxyUsesContextRoutingPolicy(t *testing.T) {
	spec := &api.LLMProxyConfigData{
		OperationPolicies: &[]api.OperationPolicy{{
			Name: "context-based-routing", Version: "v0",
			Paths: []api.OperationPolicyPath{{Path: "/*"}},
		}},
	}
	if !llmProxyUsesPolicy(spec, "context-based-routing") {
		t.Fatal("expected operation-level context router to be detected")
	}
}
