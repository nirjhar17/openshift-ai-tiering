# Implementing Tiered Rate Limiting for LLMs on OpenShift AI 3.0

*A practical guide to setting up FREE, PREMIUM, and ENTERPRISE tiers for your AI models using Kuadrant and MaaS*

---

## Introduction

When deploying Large Language Models (LLMs) in production, you often need to offer different service levels to different users. A free user might get 5 requests per minute, while an enterprise customer gets unlimited access. This is called **tiered rate limiting**.

In this article, I'll show you how to implement tiered rate limiting on **OpenShift AI 3.0** using **Kuadrant** (Red Hat Connectivity Link) and the **Models-as-a-Service (MaaS)** pattern.

## What We'll Build

By the end of this tutorial, you'll have:

- **FREE tier**: 5 requests per 2 minutes
- **PREMIUM tier**: 20 requests per 2 minutes  
- **ENTERPRISE tier**: 50 requests per 2 minutes

## The Architecture

Here's how the request flow works:

```
User Request (with Bearer Token)
        │
        ▼
┌───────────────────────────────────────────┐
│  MaaS Gateway                             │
│  (opendatahub.io/managed: "false")        │
└───────────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────────┐
│  Authorino (Authentication)               │
│  1. Validate token with Kubernetes        │
│  2. Call MaaS API to get tier             │
│  3. Check RBAC permissions                │
└───────────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────────┐
│  Limitador (Rate Limiting)                │
│  Apply tier-based limits                  │
└───────────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────────┐
│  LLM Backend (vLLM)                       │
│  Process the request                      │
└───────────────────────────────────────────┘
```

## The Key Insight: `opendatahub.io/managed: "false"`

The secret to making this work cleanly is creating a **separate Gateway** with the annotation:

```yaml
metadata:
  annotations:
    opendatahub.io/managed: "false"
```

This tells Open Data Hub: "Don't touch this gateway. Don't create any automatic policies for it."

Without this annotation, ODH auto-creates AuthPolicies that conflict with your custom configuration.

## Step-by-Step Implementation

### Step 1: Create the MaaS API

The MaaS API is a simple service that translates user groups into tier names.

```yaml
# Namespace
apiVersion: v1
kind: Namespace
metadata:
  name: maas-api
  annotations:
    opendatahub.io/managed: "false"
```

```yaml
# ConfigMap defining tiers
apiVersion: v1
kind: ConfigMap
metadata:
  name: tier-to-group-mapping
  namespace: maas-api
data:
  tiers: |
    - name: enterprise
      level: 2
      groups:
        - system:serviceaccounts:tier-enterprise
    - name: premium
      level: 1
      groups:
        - system:serviceaccounts:tier-premium
    - name: free
      level: 0
      groups:
        - system:serviceaccounts:tier-free
        - system:authenticated
```

### Step 2: Create the MaaS Gateway

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: maas-gateway
  namespace: openshift-ingress
  annotations:
    opendatahub.io/managed: "false"  # THE KEY!
spec:
  gatewayClassName: openshift-ai-inference
  listeners:
    - name: https
      port: 443
      protocol: HTTPS
      tls:
        mode: Terminate
        certificateRefs:
          - name: maas-gateway-tls
```

### Step 3: Create the AuthPolicy

```yaml
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata:
  name: maas-gateway-auth-policy
  namespace: openshift-ingress
spec:
  targetRef:
    kind: Gateway
    name: maas-gateway
  rules:
    metadata:
      matchedTier:
        http:
          url: http://maas-api.maas-api.svc.cluster.local:8080/v1/tiers/lookup
          method: POST
          body:
            expression: '{ "groups": auth.identity.user.groups }'
    authentication:
      service-accounts:
        kubernetesTokenReview:
          audiences:
            - maas-gateway
    response:
      success:
        filters:
          identity:
            json:
              properties:
                tier:
                  expression: auth.metadata.matchedTier["tier"]
```

### Step 4: Create the RateLimitPolicy

```yaml
apiVersion: kuadrant.io/v1
kind: RateLimitPolicy
metadata:
  name: maas-gateway-rate-limits
  namespace: openshift-ingress
spec:
  targetRef:
    kind: Gateway
    name: maas-gateway
  limits:
    free:
      rates:
        - limit: 5
          window: 2m
      when:
        - predicate: 'auth.identity.tier == "free"'
      counters:
        - expression: auth.identity.userid
    premium:
      rates:
        - limit: 20
          window: 2m
      when:
        - predicate: 'auth.identity.tier == "premium"'
      counters:
        - expression: auth.identity.userid
    enterprise:
      rates:
        - limit: 50
          window: 2m
      when:
        - predicate: 'auth.identity.tier == "enterprise"'
      counters:
        - expression: auth.identity.userid
```

## Testing

Generate a token for FREE tier:

```bash
FREE_TOKEN=$(oc create token test-user -n tier-free \
  --audience=maas-gateway --duration=1h)
```

Test rate limiting:

```bash
for i in {1..8}; do
  echo -n "Request $i: "
  curl -sk -w "%{http_code}" -o /dev/null \
    "https://${MAAS_URL}/my-first-model/qwen3-0-6b/v1/chat/completions" \
    -H "Authorization: Bearer ${FREE_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"model": "Qwen/Qwen3-0.6B", "messages": [{"role": "user", "content": "Hi"}]}'
  echo ""
done
```

Expected output:

```
Request 1: 200
Request 2: 200
Request 3: 200
Request 4: 200
Request 5: 200
Request 6: 429
Request 7: 429
Request 8: 429
```

## Results

| Tier | Limit | Test Result |
|------|-------|-------------|
| FREE | 5/2min | ✅ 5 requests, then 429 |
| PREMIUM | 20/2min | ✅ 20 requests, then 429 |
| ENTERPRISE | 50/2min | ✅ All requests succeeded |

## Conclusion

Implementing tiered rate limiting on OpenShift AI 3.0 is straightforward once you understand the key components:

1. **MaaS API** - Translates user groups to tier names
2. **Unmanaged Gateway** - Uses `opendatahub.io/managed: "false"` to avoid ODH conflicts
3. **AuthPolicy** - Handles token validation and tier lookup
4. **RateLimitPolicy** - Applies per-tier limits

The full code is available on GitHub: [github.com/nirjhar17/openshift-ai-tiering](https://github.com/nirjhar17/openshift-ai-tiering)

---

*Tags: OpenShift, Kubernetes, AI, LLM, Rate Limiting, Kuadrant, Red Hat*

