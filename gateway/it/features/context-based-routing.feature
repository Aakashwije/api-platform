# --------------------------------------------------------------------
# Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com).
#
# WSO2 LLC. licenses this file to you under the Apache License,
# Version 2.0 (the "License"); you may not use this file except
# in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# --------------------------------------------------------------------

@context-based-routing
Feature: Context-Based LLM Routing
  The context-based-routing policy estimates only the request input tokens and
  selects a client-configured model and optional provider using non-overlapping
  token ranges. A configured fallback handles estimation failures and unmatched
  ranges; without a fallback the original request is preserved. Malformed JSON
  is always rejected.

  Background:
    Given the gateway services are running
    And I authenticate using basic auth as "admin"

  Scenario: Input-token ranges select primary and additional providers and use fallback
    When I create this LLM provider:
      """
      apiVersion: gateway.api-platform.wso2.com/v1
      kind: LlmProvider
      metadata:
        name: context-primary-provider
      spec:
        displayName: Context Primary Provider
        version: v1.0
        template: openai
        context: /context-primary-provider
        upstream:
          url: http://sample-backend:9080/context-primary-upstream
        accessControl:
          mode: allow_all
      """
    Then the response status code should be 201

    When I create this LLM provider:
      """
      apiVersion: gateway.api-platform.wso2.com/v1
      kind: LlmProvider
      metadata:
        name: context-additional-provider
      spec:
        displayName: Context Additional Provider
        version: v1.0
        template: openai
        context: /context-additional-provider
        upstream:
          url: http://sample-backend:9080/context-additional-upstream
        accessControl:
          mode: allow_all
      """
    Then the response status code should be 201

    When I deploy this LLM proxy configuration:
      """
      apiVersion: gateway.api-platform.wso2.com/v1
      kind: LlmProxy
      metadata:
        name: context-routing-proxy
      spec:
        displayName: Context Routing Proxy
        version: v1.0
        context: /context-routing
        provider:
          id: context-primary-provider
          auth:
            type: api-key
            header: X-Context-Provider
            value: primary-context-secret
        additionalProviders:
          - id: context-additional-provider
            as: additional-context-provider
            auth:
              type: api-key
              header: X-Context-Provider
              value: additional-context-secret
        operationPolicies:
          - name: context-based-routing
            version: v0
            paths:
              - path: /chat/completions
                methods: [POST]
                params:
                  charsPerToken: 1
                  routes:
                    - name: small-context
                      maxTokens: 10
                      target:
                        model: small-context-model
                    - name: medium-context
                      minTokens: 10
                      maxTokens: 20
                      target:
                        provider: additional-context-provider
                        model: medium-context-model
                  fallback:
                    model: fallback-context-model
      """
    Then the response status should be 201
    And I wait for 3 seconds

    # "user" + "Hello" is 9 estimated characters/tokens. The very large
    # max_tokens value must not affect routing because output allowance is excluded.
    When I set header "Content-Type" to "application/json"
    And I send a POST request to "http://localhost:8080/context-routing/chat/completions" with body:
      """
      {"model":"client-model","messages":[{"role":"user","content":"Hello"}],"max_tokens":1000000}
      """
    Then the response status code should be 200
    And the response body should contain "/context-primary-upstream"
    And the response body should contain "small-context-model"
    And the response body should contain "primary-context-secret"
    And the response body should not contain "additional-context-secret"

    # "user" + "Hello!" is exactly 10. maxTokens is exclusive and minTokens
    # is inclusive, so the request must enter the second range.
    When I set header "Content-Type" to "application/json"
    And I send a POST request to "http://localhost:8080/context-routing/chat/completions" with body:
      """
      {"model":"client-model","messages":[{"role":"user","content":"Hello!"}]}
      """
    Then the response status code should be 200
    And the response body should contain "/context-additional-upstream"
    And the response body should contain "medium-context-model"
    And the response body should contain "additional-context-secret"
    And the response body should not contain "primary-context-secret"

    # No supported input field means estimation cannot be performed. The
    # configured fallback rewrites the model and uses the primary provider.
    When I set header "Content-Type" to "application/json"
    And I send a POST request to "http://localhost:8080/context-routing/chat/completions" with body:
      """
      {"model":"client-model","temperature":0.5}
      """
    Then the response status code should be 200
    And the response body should contain "/context-primary-upstream"
    And the response body should contain "fallback-context-model"
    And the response body should contain "primary-context-secret"

    # A valid input estimate outside every configured range also uses fallback.
    When I set header "Content-Type" to "application/json"
    And I send a POST request to "http://localhost:8080/context-routing/chat/completions" with body:
      """
      {"model":"client-model","prompt":"123456789012345678901"}
      """
    Then the response status code should be 200
    And the response body should contain "/context-primary-upstream"
    And the response body should contain "fallback-context-model"

    # Malformed JSON is rejected even though a fallback exists.
    When I set header "Content-Type" to "application/json"
    And I send a POST request to "http://localhost:8080/context-routing/chat/completions" with body:
      """
      {"model":"client-model","messages":
      """
    Then the response status code should be 400
    And the response body should contain "malformed JSON"
    And the response body should not contain "/context-primary-upstream"
    And the response body should not contain "/context-additional-upstream"

    When I send a DELETE request to the "gateway-controller" service at "/llm-proxies/context-routing-proxy"
    Then the response should be successful
    When I delete the LLM provider "context-primary-provider"
    Then the response status code should be 200
    When I delete the LLM provider "context-additional-provider"
    Then the response status code should be 200

  Scenario: Missing fallback preserves the client model and primary provider
    When I create this LLM provider:
      """
      apiVersion: gateway.api-platform.wso2.com/v1
      kind: LlmProvider
      metadata:
        name: context-preserve-provider
      spec:
        displayName: Context Preserve Provider
        version: v1.0
        template: openai
        context: /context-preserve-provider
        upstream:
          url: http://sample-backend:9080/context-preserve-upstream
        accessControl:
          mode: allow_all
      """
    Then the response status code should be 201

    When I deploy this LLM proxy configuration:
      """
      apiVersion: gateway.api-platform.wso2.com/v1
      kind: LlmProxy
      metadata:
        name: context-preserve-proxy
      spec:
        displayName: Context Preserve Proxy
        version: v1.0
        context: /context-preserve
        provider:
          id: context-preserve-provider
        operationPolicies:
          - name: context-based-routing
            version: v0
            paths:
              - path: /chat/completions
                methods: [POST]
                params:
                  charsPerToken: 1
                  routes:
                    - name: very-large-only
                      minTokens: 100
                      maxTokens: 1000
                      target:
                        model: very-large-context-model
      """
    Then the response status should be 201
    And I wait for 3 seconds

    # Estimation succeeds but no range matches. The client model is unchanged.
    When I set header "Content-Type" to "application/json"
    And I send a POST request to "http://localhost:8080/context-preserve/chat/completions" with body:
      """
      {"model":"keep-client-model","prompt":"short"}
      """
    Then the response status code should be 200
    And the response body should contain "/context-preserve-upstream"
    And the response body should contain "keep-client-model"
    And the response body should not contain "very-large-context-model"

    # Estimation fails for a valid object, but no fallback means passthrough.
    When I set header "Content-Type" to "application/json"
    And I send a POST request to "http://localhost:8080/context-preserve/chat/completions" with body:
      """
      {"model":"keep-unsupported-model","temperature":0.5}
      """
    Then the response status code should be 200
    And the response body should contain "keep-unsupported-model"
    And the response body should not contain "very-large-context-model"

    When I send a DELETE request to the "gateway-controller" service at "/llm-proxies/context-preserve-proxy"
    Then the response should be successful
    When I delete the LLM provider "context-preserve-provider"
    Then the response status code should be 200

  Scenario: Configured input JSONPaths select nested provider-specific request content
    When I create this LLM provider:
      """
      apiVersion: gateway.api-platform.wso2.com/v1
      kind: LlmProvider
      metadata:
        name: context-jsonpath-provider
      spec:
        displayName: Context JSONPath Provider
        version: v1.0
        template: openai
        context: /context-jsonpath-provider
        upstream:
          url: http://sample-backend:9080/context-jsonpath-upstream
        accessControl:
          mode: allow_all
      """
    Then the response status code should be 201

    When I deploy this LLM proxy configuration:
      """
      apiVersion: gateway.api-platform.wso2.com/v1
      kind: LlmProxy
      metadata:
        name: context-jsonpath-proxy
      spec:
        displayName: Context JSONPath Proxy
        version: v1.0
        context: /context-jsonpath
        provider:
          id: context-jsonpath-provider
        operationPolicies:
          - name: context-based-routing
            version: v0
            paths:
              - path: /chat/completions
                methods: [POST]
                params:
                  charsPerToken: 1
                  inputJSONPaths:
                    - $.request.turns.*.text
                  routes:
                    - name: short-custom-input
                      maxTokens: 10
                      target:
                        model: jsonpath-short-model
                    - name: exact-custom-boundary
                      minTokens: 10
                      maxTokens: 20
                      target:
                        model: jsonpath-selected-model
                  fallback:
                    model: jsonpath-fallback-model
      """
    Then the response status should be 201
    And I wait for 3 seconds

    # Only the two configured nested text values are counted: "hello" +
    # "world" = 10. The large prompt is ignored, so the second route is used.
    When I set header "Content-Type" to "application/json"
    And I send a POST request to "http://localhost:8080/context-jsonpath/chat/completions" with body:
      """
      {"model":"client-model","request":{"turns":[{"text":"hello"},{"text":"world"}]},"prompt":"this default-path text must not affect the configured JSONPath estimate"}
      """
    Then the response status code should be 200
    And the response body should contain "/context-jsonpath-upstream"
    And the response body should contain "jsonpath-selected-model"
    And the response body should not contain "jsonpath-short-model"
    And the response body should not contain "jsonpath-fallback-model"

    # Configuring inputJSONPaths replaces the built-in defaults. A request that
    # contains only a default prompt path therefore uses the configured fallback.
    When I set header "Content-Type" to "application/json"
    And I send a POST request to "http://localhost:8080/context-jsonpath/chat/completions" with body:
      """
      {"model":"client-model","prompt":"hello"}
      """
    Then the response status code should be 200
    And the response body should contain "jsonpath-fallback-model"
    And the response body should not contain "jsonpath-selected-model"

    When I send a DELETE request to the "gateway-controller" service at "/llm-proxies/context-jsonpath-proxy"
    Then the response should be successful
    When I delete the LLM provider "context-jsonpath-provider"
    Then the response status code should be 200

  Scenario: Native Bedrock and Gemini provider path model locations are rewritten
    When I create this LLM provider:
      """
      apiVersion: gateway.api-platform.wso2.com/v1
      kind: LlmProvider
      metadata:
        name: context-bedrock-provider
      spec:
        displayName: Context Bedrock Provider
        version: v1.0
        template: awsbedrock
        context: /context-bedrock-provider
        upstream:
          url: http://sample-backend:9080/context-bedrock-upstream
        accessControl:
          mode: allow_all
        operationPolicies:
          - name: context-based-routing
            version: v0
            paths:
              - path: /model/{modelId}/converse
                methods: [POST]
                params:
                  charsPerToken: 1
                  routes:
                    - maxTokens: 100
                      target:
                        model: anthropic.claude-3-5-sonnet-20241022-v2:0
      """
    Then the response status code should be 201
    And I wait for the endpoint "http://localhost:8080/context-bedrock-provider/model/client-model/converse" to be ready with method "POST" and body '{"prompt":"hello"}'

    When I set header "Content-Type" to "application/json"
    And I send a POST request to "http://localhost:8080/context-bedrock-provider/model/client-model/converse" with body:
      """
      {"prompt":"hello"}
      """
    Then the response status code should be 200
    And the response body should contain "/context-bedrock-upstream/model/anthropic.claude-3-5-sonnet-20241022-v2:0/converse"

    When I delete the LLM provider "context-bedrock-provider"
    Then the response status code should be 200

    When I create this LLM provider:
      """
      apiVersion: gateway.api-platform.wso2.com/v1
      kind: LlmProvider
      metadata:
        name: context-gemini-provider
      spec:
        displayName: Context Gemini Provider
        version: v1.0
        template: gemini
        context: /context-gemini-provider
        upstream:
          url: http://sample-backend:9080/context-gemini-upstream
        accessControl:
          mode: allow_all
        operationPolicies:
          - name: context-based-routing
            version: v0
            paths:
              - path: /v1beta/models/{model}:generateContent
                methods: [POST]
                params:
                  charsPerToken: 1
                  routes:
                    - maxTokens: 100
                      target:
                        model: gemini-2.0-flash
      """
    Then the response status code should be 201
    And I wait for the endpoint "http://localhost:8080/context-gemini-provider/v1beta/models/client-model:generateContent" to be ready with method "POST" and body '{"contents":[{"parts":[{"text":"hello"}]}]}'

    When I set header "Content-Type" to "application/json"
    And I send a POST request to "http://localhost:8080/context-gemini-provider/v1beta/models/client-model:generateContent" with body:
      """
      {"contents":[{"parts":[{"text":"hello"}]}]}
      """
    Then the response status code should be 200
    And the response body should contain "/context-gemini-upstream/v1beta/models/gemini-2.0-flash:generateContent"

    When I delete the LLM provider "context-gemini-provider"
    Then the response status code should be 200
