#!/bin/bash

set -uo pipefail

SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
[[ -n "${DEBUG:-}" ]] && set -x

# Delete ArgoCD ApplicationSets before removing the cluster
TMPFILE=$(mktemp)
terraform -chdir="$SCRIPTDIR" output -raw configure_kubectl > "$TMPFILE"
if [[ ! $(cat "$TMPFILE") == *"No outputs found"* ]]; then
  source "$TMPFILE"
  kubectl delete -n argocd applicationset workloads          --ignore-not-found
  kubectl delete -n argocd applicationset cluster-addons     --ignore-not-found
  kubectl delete -n argocd applicationset addons-argocd      --ignore-not-found
  kubectl delete -n argocd svc argo-cd-argocd-server         --ignore-not-found
fi

terraform -chdir="$SCRIPTDIR" destroy -target="module.gitops_bridge_bootstrap" -auto-approve
terraform -chdir="$SCRIPTDIR" destroy -target="module.eks_blueprints_addons"   -auto-approve
terraform -chdir="$SCRIPTDIR" destroy -target="module.eks"                      -auto-approve
terraform -chdir="$SCRIPTDIR" destroy -target="module.vpc"                      -auto-approve
terraform -chdir="$SCRIPTDIR" destroy -auto-approve
