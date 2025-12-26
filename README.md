# Tiered Rate Limiting for OpenShift AI 3.0

Implement FREE, PREMIUM, and ENTERPRISE tiers for your LLM models using Kuadrant and MaaS API.

## Overview

This project implements tiered rate limiting on OpenShift AI 3.0:

| Tier | Requests per 2 minutes |
|------|------------------------|
| FREE | 5 |
| PREMIUM | 20 |
| ENTERPRISE | 50 |

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

### Step 4: Create TLS Certificate

```bash
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /tmp/tls.key -out /tmp/tls.crt \
  -subj "/CN=maas-gateway"

oc create secret tls maas-gateway-tls \
  --cert=/tmp/tls.crt --key=/tmp/tls.key \
  -n openshift-ingress

rm /tmp/tls.key /tmp/tls.crt
```

### Step 5: Create MaaS Gateway

```bash
oc apply -f 04-maas-gateway.yaml
```

Wait for Gateway:

```bash
oc get gateway maas-gateway -n openshift-ingress -w
```

### Step 6: Create HTTPRoute

```bash
oc apply -f 05-maas-httproute.yaml
```

### Step 7: Create AuthPolicy

```bash
oc apply -f 06-auth-policy.yaml
```

### Step 8: Create RateLimitPolicy

```bash
oc apply -f 07-rate-limit-policy.yaml
```

### Step 9: Create Test Users

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

## How It Works

```
User Request → MaaS Gateway → Authorino → MaaS API → Limitador → Model
                    │              │           │          │
                    │              │           │          └── Apply rate limit
                    │              │           └── Return tier (free/premium/enterprise)
                    │              └── Validate token, get user groups
                    └── opendatahub.io/managed: "false" (ODH won't create policies)
```

The key is `opendatahub.io/managed: "false"` annotation on the Gateway. This prevents ODH from auto-creating conflicting policies.

## Customization

### Change Rate Limits

Edit `07-rate-limit-policy.yaml`:

```yaml
limits:
  free:
    rates:
      - limit: 10    # Change limit
        window: 1m   # Change window
```

### Add New Model

Edit `05-maas-httproute.yaml` to add routes for your model.

## Troubleshooting

| Error | Solution |
|-------|----------|
| 401 Unauthorized | Check token audience: `--audience=maas-gateway` |
| 429 Too Many Requests | Rate limit working! Wait 2 minutes |
| 500 Internal Server Error | Check: `oc logs -n kuadrant-system deployment/authorino` |

---

## Note: Alternative Approach

We initially tried an HTTPRoute-level approach that works with the ODH-managed Gateway. This requires scaling down the ODH controller temporarily:

```bash
oc scale deployment odh-model-controller -n redhat-ods-applications --replicas=0
# Apply policies
oc scale deployment odh-model-controller -n redhat-ods-applications --replicas=1
```

See `docs/alternative-approach.md` for details.

The Gateway-level approach (this README) is recommended because it has no conflicts with ODH.

