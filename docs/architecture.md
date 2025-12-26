# Architecture: Complete Request Flow

## Visual Flow

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              COMPLETE REQUEST FLOW                               │
└─────────────────────────────────────────────────────────────────────────────────┘

  User Request (with Bearer Token)
        │
        ▼
┌───────────────────────────────────────────────────────────────────────────────┐
│  1. GATEWAY (maas-gateway)                                                     │
│     • Receives HTTPS request                                                   │
│     • Terminates TLS                                                           │
│     • Has annotation: opendatahub.io/managed: "false"                          │
└───────────────────────────────────────────────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────────────────────────────────────────────┐
│  2. WASM PLUGIN (auto-created by Kuadrant)                                     │
│     • Intercepts request BEFORE it reaches backend                             │
│     • Contains two services:                                                   │
│       - auth-service (calls Authorino)                                         │
│       - ratelimit-service (calls Limitador)                                    │
└───────────────────────────────────────────────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────────────────────────────────────────────┐
│  3. AUTHORINO (Authentication & Authorization)                                 │
│     Located in: kuadrant-system namespace                                      │
│                                                                                │
│     Step 3a: kubernetesTokenReview                                             │
│     • Validates the Bearer token with Kubernetes API                           │
│     • Returns: username, groups                                                │
│                                                                                │
│     Step 3b: HTTP Metadata (Call MaaS API)                                     │
│     • POST http://maas-api.maas-api.svc.cluster.local:8080/v1/tiers/lookup     │
│     • Body: {"groups": ["system:serviceaccounts:tier-premium"]}                │
│     • Response: {"tier": "premium"}                                            │
│                                                                                │
│     Step 3c: kubernetesSubjectAccessReview (RBAC Check)                        │
│     • Checks if user has permission to access the LLMInferenceService          │
│                                                                                │
│     Step 3d: Response Filter                                                   │
│     • Adds to request context: auth.identity.tier = "premium"                  │
└───────────────────────────────────────────────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────────────────────────────────────────────┐
│  4. LIMITADOR (Rate Limiting)                                                  │
│     Located in: kuadrant-system namespace                                      │
│                                                                                │
│     • Receives auth.identity.tier from Authorino                               │
│     • Checks RateLimitPolicy:                                                  │
│       - if tier == "free": limit 5/2min                                        │
│       - if tier == "premium": limit 20/2min                                    │
│       - if tier == "enterprise": limit 50/2min                                 │
│     • If under limit: ALLOW                                                    │
│     • If over limit: REJECT with 429                                           │
└───────────────────────────────────────────────────────────────────────────────┘
        │
        ▼ (if allowed)
┌───────────────────────────────────────────────────────────────────────────────┐
│  5. HTTPROUTE                                                                  │
│     • Routes request to model backend                                          │
│     • Rewrites path: /my-first-model/qwen3-0-6b → /v1/chat/completions         │
└───────────────────────────────────────────────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────────────────────────────────────────────┐
│  6. MODEL BACKEND (vLLM)                                                       │
│     • Processes the LLM request                                                │
│     • Returns response                                                         │
└───────────────────────────────────────────────────────────────────────────────┘


## Namespace Layout

```
openshift-ingress/
├── Gateway: maas-gateway
├── AuthPolicy: maas-gateway-auth-policy
├── RateLimitPolicy: maas-gateway-rate-limits
└── WasmPlugin: kuadrant-maas-gateway (auto-created)

kuadrant-system/
├── Deployment: authorino
└── Deployment: limitador-limitador

maas-api/
├── Deployment: maas-api
├── Service: maas-api
└── ConfigMap: tier-to-group-mapping

my-first-model/
├── LLMInferenceService: qwen3-0-6b
├── HTTPRoute: maas-model-route
└── InferencePool: qwen3-0-6b-inference-pool

tier-free/
└── ServiceAccount: test-user

tier-premium/
└── ServiceAccount: test-user

tier-enterprise/
└── ServiceAccount: test-user
```

## Component Details

### Gateway
- Kubernetes Gateway API resource
- Entry point for all traffic
- KEY: `opendatahub.io/managed: "false"` prevents ODH interference

### WasmPlugin
- Istio extension running WebAssembly in Envoy proxy
- Auto-created by Kuadrant when you create AuthPolicy/RateLimitPolicy
- You never create this manually

### Authorino
- Kuadrant's authentication engine
- Runs in kuadrant-system namespace
- Processes AuthPolicy rules

### MaaS API
- Simple Go application (not an operator)
- Reads ConfigMap, returns tier name
- Image: quay.io/opendatahub/maas-api:latest

### Limitador
- Kuadrant's rate limiting engine
- Runs in kuadrant-system namespace
- Processes RateLimitPolicy rules

### HTTPRoute
- Kubernetes Gateway API resource
- Routes traffic from Gateway to backend

