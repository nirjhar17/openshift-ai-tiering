# Alternative Approach: HTTPRoute-Level Policies

This was our first approach before using the Gateway-level method.

## When to Use This

Use this approach if you:
- Cannot create a new Gateway
- Want to use the existing ODH-managed Gateway

## Steps

### 1. Set enable-auth to false on LLMInferenceService

```bash
oc annotate llminferenceservice qwen3-0-6b -n my-first-model \
  security.opendatahub.io/enable-auth=false --overwrite
```

### 2. Scale down ODH controller

```bash
oc scale deployment odh-model-controller -n redhat-ods-applications --replicas=0
```

### 3. Delete ODH-created policies

```bash
oc delete authpolicy qwen3-0-6b-kserve-route-authn -n my-first-model
oc delete authpolicy openshift-ai-inference-authn -n openshift-ingress
oc delete envoyfilter authn-filter -n openshift-ingress
oc delete envoyfilter openshift-ai-inference-authn-ssl -n openshift-ingress
```

### 4. Create HTTPRoute-level AuthPolicy

The AuthPolicy targets the HTTPRoute instead of Gateway:

```yaml
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata:
  name: qwen3-0-6b-kserve-route-authn
  namespace: my-first-model
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute  # Target HTTPRoute, not Gateway
    name: qwen3-0-6b-kserve-route
  # ... same rules as Gateway-level
```

### 5. Create HTTPRoute-level RateLimitPolicy

```yaml
apiVersion: kuadrant.io/v1
kind: RateLimitPolicy
metadata:
  name: qwen3-0-6b-kserve-route-ratelimit
  namespace: my-first-model
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: qwen3-0-6b-kserve-route
  # ... same limits
```

### 6. Scale ODH controller back up

```bash
oc scale deployment odh-model-controller -n redhat-ods-applications --replicas=1
```

## Why We Moved to Gateway-Level

| Aspect | HTTPRoute-Level | Gateway-Level |
|--------|-----------------|---------------|
| ODH conflicts | Need workarounds | None |
| Maintenance | Watch for ODH changes | Set and forget |
| Scope | Per-model policies | One policy for all |

The Gateway-level approach with `opendatahub.io/managed: "false"` is simpler and more reliable.

