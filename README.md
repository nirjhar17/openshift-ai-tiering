# Tiered Rate Limiting for OpenShift AI 3.0

Implement FREE, PREMIUM, and ENTERPRISE tiers for your LLM models.

---

## Explanation: How It Works

### What We're Trying to Do

We want different users to get different rate limits:
- FREE users: 5 requests per 2 minutes
- PREMIUM users: 20 requests per 2 minutes
- ENTERPRISE users: 50 requests per 2 minutes

### The Components and How They Talk

**1. Gateway**

The Gateway is the entry point. All requests come through here first. We create a separate Gateway called `maas-gateway` with a special annotation `opendatahub.io/managed: "false"`. This annotation tells ODH (Open Data Hub): "Don't touch this gateway, don't create any policies for it". Without this annotation, ODH auto-creates its own policies which conflict with ours.

**2. WasmPlugin**

When you create an AuthPolicy or RateLimitPolicy, Kuadrant automatically creates a WasmPlugin. You never create this yourself. The WasmPlugin sits inside the Gateway's Envoy proxy. It intercepts every request before it reaches your model. The WasmPlugin has two jobs:
- Call Authorino for authentication
- Call Limitador for rate limiting

**3. Authorino**

Authorino is the authentication service. It runs as a pod in `kuadrant-system` namespace. When a request comes in, the WasmPlugin sends the user's token to Authorino. Authorino does three things:
- Validates the token with Kubernetes (is this token real?)
- Calls MaaS API to find out the user's tier
- Checks RBAC (does this user have permission to access the model?)

**4. MaaS API**

MaaS API is a simple Go application we deploy. It reads a ConfigMap that defines which groups belong to which tier. When Authorino asks "what tier is this user?", MaaS API looks at the user's groups and returns "free" or "premium" or "enterprise". Think of it as a translator: groups → tier name.

**5. Limitador**

Limitador is the rate limiting service. It also runs in `kuadrant-system` namespace. After Authorino says "this user is premium tier", the WasmPlugin passes this to Limitador. Limitador checks: "How many requests has this premium user made in the last 2 minutes? Is it under 20?" If yes, allow. If no, return 429 (too many requests).

**6. HTTPRoute**

The HTTPRoute tells the Gateway how to send traffic to your model. It says: "When someone calls /my-first-model/qwen3-0-6b, send it to the model's backend service".

### The Complete Flow

```
User sends request with token
         ↓
    Gateway receives it
         ↓
    WasmPlugin intercepts
         ↓
    Calls Authorino → Authorino validates token
                    → Authorino calls MaaS API → Returns "premium"
                    → Authorino checks RBAC → User has access
         ↓
    WasmPlugin now knows: user=test-user, tier=premium
         ↓
    Calls Limitador → Checks: premium limit is 20/2min
                    → User has made 15 requests → ALLOW
         ↓
    HTTPRoute sends request to model
         ↓
    Model returns response
```

### Why Namespace-Based Tiers?

When Kubernetes validates a ServiceAccount token, it returns groups like:
- `system:serviceaccounts`
- `system:serviceaccounts:tier-premium` (based on namespace)

It does NOT return OpenShift Groups. So we put users in different namespaces:
- User in `tier-free` namespace → FREE tier
- User in `tier-premium` namespace → PREMIUM tier
- User in `tier-enterprise` namespace → ENTERPRISE tier

### Key Files Summary

| File | What It Does |
|------|--------------|
| 04-maas-gateway.yaml | Creates Gateway that ODH won't manage |
| 03-maas-api-deployment.yaml | Deploys the tier lookup service |
| 02-tier-configmap.yaml | Defines which namespace = which tier |
| 06-auth-policy.yaml | Tells Authorino how to authenticate and get tier |
| 07-rate-limit-policy.yaml | Tells Limitador the limits per tier |

---

## Prerequisites

- OpenShift AI 3.0 cluster
- Kuadrant operator installed
- An LLMInferenceService deployed
- `oc` CLI configured

## Quick Start

```bash
./deploy.sh
```

## Step-by-Step Guide

### Step 1: Create MaaS API Namespace

```bash
oc apply -f 01-maas-namespace.yaml
```

### Step 2: Create Tier ConfigMap

```bash
oc apply -f 02-tier-configmap.yaml
```

### Step 3: Deploy MaaS API

```bash
oc apply -f 03-maas-api-deployment.yaml
oc rollout status deployment/maas-api -n maas-api --timeout=120s
```

### Step 4: Create MaaS Gateway

Note: This Gateway reuses the existing `default-gateway-tls` certificate.

```bash
oc apply -f 04-maas-gateway.yaml
```

Wait for Gateway:

```bash
oc get gateway maas-gateway -n openshift-ingress -w
```

### Step 5: Create HTTPRoute

```bash
oc apply -f 05-maas-httproute.yaml
```

### Step 6: Create AuthPolicy

```bash
oc apply -f 06-auth-policy.yaml
```

### Step 7: Create RateLimitPolicy

```bash
oc apply -f 07-rate-limit-policy.yaml
```

### Step 8: Create Test Users

```bash
oc apply -f 08-tier-test-namespaces.yaml
```

## Testing

### Get Gateway URL

```bash
MAAS_URL=$(oc get gateway maas-gateway -n openshift-ingress -o jsonpath='{.status.addresses[0].value}')
```

### Generate Token

```bash
# FREE tier
FREE_TOKEN=$(oc create token test-user -n tier-free --audience=maas-gateway --duration=1h)

# PREMIUM tier
PREMIUM_TOKEN=$(oc create token test-user -n tier-premium --audience=maas-gateway --duration=1h)

# ENTERPRISE tier
ENTERPRISE_TOKEN=$(oc create token test-user -n tier-enterprise --audience=maas-gateway --duration=1h)
```

### Test Request

```bash
curl -sk "https://${MAAS_URL}/my-first-model/qwen3-0-6b/v1/chat/completions" \
  -H "Authorization: Bearer ${FREE_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"model": "Qwen/Qwen3-0.6B", "messages": [{"role": "user", "content": "Hello"}]}'
```

### Run Test Script

```bash
./test-tiering.sh
```

## Rate Limits

| Tier | Namespace | Requests per 2 minutes |
|------|-----------|------------------------|
| FREE | tier-free | 5 |
| PREMIUM | tier-premium | 20 |
| ENTERPRISE | tier-enterprise | 50 |

## Troubleshooting

| Error | Solution |
|-------|----------|
| 401 Unauthorized | Token wrong audience. Use `--audience=maas-gateway` |
| 429 Too Many Requests | Rate limit working. Wait 2 minutes |
| 500 Internal Server Error | Check: `oc logs -n kuadrant-system deployment/authorino` |
| Gateway not ready | Check GatewayClass matches existing Gateway |

---

## Note: Alternative Approach

We first tried an HTTPRoute-level approach using the existing ODH-managed Gateway. This required scaling down ODH controller temporarily. See `docs/alternative-approach.md` for details.

The Gateway-level approach (this README) is recommended because ODH doesn't interfere.
