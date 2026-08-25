/*
 * Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com).
 * Licensed under the Apache License, Version 2.0.
 */

package config

import (
	"fmt"
	"sort"
	"strings"

	api "github.com/wso2/api-platform/gateway/gateway-controller/pkg/api/management"
)

const contextBasedRoutingPolicyName = "context-based-routing"

// These policies actively choose a model or provider and therefore cannot
// overlap context-based-routing. model-access-control is intentionally absent:
// it validates a model and can run before routing to validate the client's
// requested model, or after routing to validate the selected upstream model.
var contextConflictingRouters = map[string]struct{}{
	"context-based-routing":      {},
	"model-round-robin":          {},
	"model-weighted-round-robin": {},
	"llm-header-router":          {},
}

type contextPolicyAttachment struct {
	name    string
	path    string
	methods []string
	params  map[string]interface{}
	field   string
}

func validateContextBasedRoutingPolicies(spec *api.LLMProxyConfigData) []ValidationError {
	if spec == nil {
		return nil
	}
	attachments := collectContextPolicyAttachments(spec)
	additionalProviders := contextAdditionalProviderAliases(spec)
	var routingAttachments []contextPolicyAttachment
	var errors []ValidationError

	for _, attached := range attachments {
		if attached.name != contextBasedRoutingPolicyName {
			continue
		}
		errors = append(errors, validateContextRouteProviders(attached.field+".params", attached.params, additionalProviders)...)
		for _, existing := range routingAttachments {
			if contextAttachmentsOverlap(existing, attached) {
				errors = append(errors, ValidationError{
					Field:   attached.field,
					Message: "context-based-routing is attached more than once to overlapping operations",
				})
				break
			}
		}
		routingAttachments = append(routingAttachments, attached)
	}

	for _, attached := range attachments {
		if attached.name == contextBasedRoutingPolicyName {
			continue
		}
		if _, conflict := contextConflictingRouters[attached.name]; !conflict {
			continue
		}
		for _, router := range routingAttachments {
			if contextAttachmentsOverlap(router, attached) {
				errors = append(errors, ValidationError{
					Field:   attached.field,
					Message: fmt.Sprintf("policy '%s' cannot overlap context-based-routing because both select the model or provider", attached.name),
				})
				break
			}
		}
	}
	return errors
}

func contextAdditionalProviderAliases(spec *api.LLMProxyConfigData) map[string]struct{} {
	result := make(map[string]struct{})
	if spec.AdditionalProviders == nil {
		return result
	}
	for _, provider := range *spec.AdditionalProviders {
		name := strings.TrimSpace(provider.Id)
		if provider.As != nil && strings.TrimSpace(*provider.As) != "" {
			name = strings.TrimSpace(*provider.As)
		}
		if name != "" {
			result[name] = struct{}{}
		}
	}
	return result
}

func validateContextRouteProviders(field string, params map[string]interface{}, providers map[string]struct{}) []ValidationError {
	var errors []ValidationError
	checkTarget := func(targetField string, raw interface{}) {
		target, ok := raw.(map[string]interface{})
		if !ok {
			return
		}
		provider, ok := target["provider"].(string)
		provider = strings.TrimSpace(provider)
		if !ok || provider == "" {
			return
		}
		if _, exists := providers[provider]; exists {
			return
		}
		errors = append(errors, ValidationError{
			Field: targetField + ".provider",
			Message: fmt.Sprintf("unknown additional provider '%s'; use one of [%s], or omit provider to use the primary provider",
				provider, formatContextProviders(providers)),
		})
	}
	if routes, ok := params["routes"].([]interface{}); ok {
		for i, raw := range routes {
			if route, ok := raw.(map[string]interface{}); ok {
				checkTarget(fmt.Sprintf("%s.routes[%d].target", field, i), route["target"])
			}
		}
	}
	if fallback, exists := params["fallback"]; exists {
		checkTarget(field+".fallback", fallback)
	}
	return errors
}

func formatContextProviders(providers map[string]struct{}) string {
	names := make([]string, 0, len(providers))
	for name := range providers {
		names = append(names, name)
	}
	sort.Strings(names)
	return strings.Join(names, ", ")
}

func collectContextPolicyAttachments(spec *api.LLMProxyConfigData) []contextPolicyAttachment {
	var result []contextPolicyAttachment
	if spec.GlobalPolicies != nil {
		for i, attached := range *spec.GlobalPolicies {
			params := map[string]interface{}{}
			if attached.Params != nil {
				params = *attached.Params
			}
			result = append(result, contextPolicyAttachment{
				name: attached.Name, path: "/*", methods: []string{"*"}, params: params,
				field: fmt.Sprintf("spec.globalPolicies[%d]", i),
			})
		}
	}
	if spec.OperationPolicies != nil {
		for i, attached := range *spec.OperationPolicies {
			for j, path := range attached.Paths {
				result = append(result, contextPolicyAttachment{
					name: attached.Name, path: path.Path, methods: contextMethods(path.Methods), params: path.Params,
					field: fmt.Sprintf("spec.operationPolicies[%d].paths[%d]", i, j),
				})
			}
		}
	}
	if spec.Policies != nil {
		for i, attached := range *spec.Policies {
			for j, path := range attached.Paths {
				methods := make([]string, 0, len(path.Methods))
				for _, method := range path.Methods {
					methods = append(methods, strings.ToUpper(strings.TrimSpace(string(method))))
				}
				if len(methods) == 0 {
					methods = []string{"*"}
				}
				result = append(result, contextPolicyAttachment{
					name: attached.Name, path: path.Path, methods: methods, params: path.Params,
					field: fmt.Sprintf("spec.policies[%d].paths[%d]", i, j),
				})
			}
		}
	}
	return result
}

func contextMethods(methods []api.OperationPolicyPathMethods) []string {
	if len(methods) == 0 {
		return []string{"*"}
	}
	result := make([]string, 0, len(methods))
	for _, method := range methods {
		result = append(result, strings.ToUpper(strings.TrimSpace(string(method))))
	}
	return result
}

func contextAttachmentsOverlap(left, right contextPolicyAttachment) bool {
	if !contextPathsOverlap(left.path, right.path) {
		return false
	}
	for _, leftMethod := range left.methods {
		for _, rightMethod := range right.methods {
			if leftMethod == "*" || rightMethod == "*" || leftMethod == rightMethod {
				return true
			}
		}
	}
	return false
}

func contextPathsOverlap(left, right string) bool {
	if left == right || left == "/*" || right == "/*" {
		return true
	}
	leftPrefix, leftWildcard := contextPathPrefix(left)
	rightPrefix, rightWildcard := contextPathPrefix(right)
	if leftWildcard && rightWildcard {
		return strings.HasPrefix(leftPrefix, rightPrefix) || strings.HasPrefix(rightPrefix, leftPrefix)
	}
	if leftWildcard {
		return strings.HasPrefix(right, leftPrefix)
	}
	if rightWildcard {
		return strings.HasPrefix(left, rightPrefix)
	}
	return false
}

func contextPathPrefix(path string) (string, bool) {
	index := strings.Index(path, "*")
	if index < 0 {
		return path, false
	}
	return path[:index], true
}
