# Deploy namespace and secrets
kubectl apply -f k8s-namespace-secrets.yaml

# Deploy backend
kubectl apply -f backend-deployment.yaml

# Deploy frontend
kubectl apply -f frontend-deployment.yaml

# Deploy ingress (optional, if using custom domain or Application Gateway)
kubectl apply -f ingress.yaml
