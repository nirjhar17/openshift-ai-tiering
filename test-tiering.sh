#!/bin/bash
# Test tiered rate limiting
set -e

MAAS_URL=$(oc get gateway maas-gateway -n openshift-ingress -o jsonpath='{.status.addresses[0].value}')
MODEL_PATH="/my-first-model/qwen3-0-6b"

echo "=== Testing Tiered Rate Limiting ==="
echo "Gateway: https://${MAAS_URL}"
echo ""

test_tier() {
    local tier=$1
    local namespace=$2
    local limit=$3
    
    echo "--- ${tier} tier (limit: ${limit}/2min) ---"
    TOKEN=$(oc create token test-user -n "${namespace}" --audience=maas-gateway --duration=1h)
    
    success=0
    for i in $(seq 1 $((limit + 3))); do
        code=$(curl -sk -w "%{http_code}" -o /dev/null \
            "https://${MAAS_URL}${MODEL_PATH}/v1/chat/completions" \
            -H "Authorization: Bearer ${TOKEN}" \
            -H "Content-Type: application/json" \
            -d '{"model": "Qwen/Qwen3-0.6B", "messages": [{"role": "user", "content": "Hi"}], "max_tokens": 3}')
        [ "$code" == "200" ] && success=$((success + 1))
    done
    
    echo "Successful: ${success}/${limit} (expected: ${limit})"
    [ "$success" -le "$limit" ] && echo "✓ Rate limiting working" || echo "✗ Check configuration"
    echo ""
}

test_tier "FREE" "tier-free" 5
test_tier "PREMIUM" "tier-premium" 20
test_tier "ENTERPRISE" "tier-enterprise" 50

echo "=== Test Complete ==="

