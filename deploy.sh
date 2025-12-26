#!/bin/bash
# Deploy tiered rate limiting for OpenShift AI 3.0
set -e

echo "=== Deploying Tiered Rate Limiting ==="

echo "Step 1: Create MaaS API namespace..."
oc apply -f 01-maas-namespace.yaml

echo "Step 2: Create tier ConfigMap..."
oc apply -f 02-tier-configmap.yaml

echo "Step 3: Deploy MaaS API..."
oc apply -f 03-maas-api-deployment.yaml
echo "Waiting for MaaS API..."
oc rollout status deployment/maas-api -n maas-api --timeout=120s

echo "Step 4: Create MaaS Gateway (uses existing default-gateway-tls cert)..."
oc apply -f 04-maas-gateway.yaml
echo "Waiting for Gateway (30s)..."
sleep 30

echo "Step 5: Create HTTPRoute..."
oc apply -f 05-maas-httproute.yaml

echo "Step 6: Create AuthPolicy..."
oc apply -f 06-auth-policy.yaml

echo "Step 7: Create RateLimitPolicy..."
oc apply -f 07-rate-limit-policy.yaml

echo "Step 8: Create test namespaces..."
oc apply -f 08-tier-test-namespaces.yaml

echo ""
echo "=== Deployment Complete ==="
MAAS_URL=$(oc get gateway maas-gateway -n openshift-ingress -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo "pending")
echo "Gateway URL: https://${MAAS_URL}"
echo ""
echo "Test with: ./test-tiering.sh"

