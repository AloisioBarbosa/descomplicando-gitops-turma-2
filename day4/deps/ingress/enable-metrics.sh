#!/bin/bash
# Enable Prometheus metrics for NGINX Ingress Controller
# This script patches the existing ingress-nginx deployment to expose metrics

set -e

echo "Patching NGINX Ingress Controller to enable metrics..."

# Step 1: Add prometheus scraping annotations
echo "Adding prometheus annotations..."
kubectl patch deployment ingress-nginx-controller -n ingress-nginx --type merge -p '{
  "spec": {
    "template": {
      "metadata": {
        "annotations": {
          "prometheus.io/scrape": "true",
          "prometheus.io/port": "10254"
        }
      }
    }
  }
}'

# Step 2: Add the prometheus port to the container (using JSON patch)
echo "Adding prometheus port..."
kubectl patch deployment ingress-nginx-controller -n ingress-nginx --type json -p '[
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/ports/-",
    "value": {
      "name": "prometheus",
      "containerPort": 10254,
      "protocol": "TCP"
    }
  }
]' || echo "Port may already exist, continuing..."

# Step 3: Add --enable-metrics=true to args if not present
echo "Checking if metrics are already enabled..."
CURRENT_ARGS=$(kubectl get deployment ingress-nginx-controller -n ingress-nginx -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null || echo "[]")

if echo "$CURRENT_ARGS" | grep -q "enable-metrics"; then
  echo "Metrics already enabled, skipping..."
else
  echo "Enabling metrics..."
  kubectl patch deployment ingress-nginx-controller -n ingress-nginx --type json -p '[
    {
      "op": "add",
      "path": "/spec/template/spec/containers/0/args/-",
      "value": "--enable-metrics=true"
    }
  ]'
fi

# Create the metrics service
echo "Creating metrics service..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: ingress-nginx-controller-metrics
  namespace: ingress-nginx
  labels:
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/component: controller
spec:
  type: ClusterIP
  ports:
    - name: prometheus
      port: 10254
      targetPort: prometheus
      protocol: TCP
  selector:
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/component: controller
EOF

# Create the ServiceMonitor for Prometheus Operator
echo "Creating ServiceMonitor..."
cat <<EOF | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: ingress-nginx-controller
  namespace: ingress-nginx
  labels:
    release: prometheus
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: ingress-nginx
      app.kubernetes.io/instance: ingress-nginx
      app.kubernetes.io/component: controller
  endpoints:
    - port: prometheus
      interval: 15s
      scrapeTimeout: 10s
      path: /metrics
  namespaceSelector:
    matchNames:
      - ingress-nginx
EOF

echo ""
echo "✓ NGINX Ingress Controller metrics enabled!"
echo ""
echo "Note: The deployment will roll out new pods. Wait for them to be ready:"
echo "  kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx"
echo ""
echo "Prometheus queries you can use:"
echo "  - nginx_ingress_controller_requests"
echo "  - nginx_ingress_controller_request_duration_seconds"
echo "  - rate(nginx_ingress_controller_requests{status=~'5..'}[5m])"
