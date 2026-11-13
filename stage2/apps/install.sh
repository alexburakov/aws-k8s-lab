#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
export KUBECONFIG=${KUBECONFIG:-$HOME/lab/inventory/artifacts/admin.conf}

helm upgrade --install podinfo oci://ghcr.io/stefanprodan/charts/podinfo --version 6.17.0 \
  -n podinfo --create-namespace -f podinfo-values.yaml

kubectl apply -f cluster-issuer.yaml

helm upgrade --install postgresql oci://registry-1.docker.io/bitnamicharts/postgresql --version 15.5.20 \
  -n db --create-namespace -f postgresql-values.yaml -f postgresql-legacy-images.yaml

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >/dev/null
helm upgrade --install kps prometheus-community/kube-prometheus-stack --version 61.9.0 \
  -n monitoring --create-namespace -f kps-values.yaml

kubectl apply -f legacy.yaml
kubectl apply -f writer.yaml
