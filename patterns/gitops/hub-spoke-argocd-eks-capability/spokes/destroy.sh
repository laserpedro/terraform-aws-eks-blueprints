#!/bin/bash

set -uo pipefail

SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
[[ -n "${DEBUG:-}" ]] && set -x

if [[ $# -eq 0 ]] ; then
    echo "No arguments supplied"
    echo "Usage: destroy.sh <environment>"
    echo "Example: destroy.sh dev"
    exit 1
fi
env=$1

terraform -chdir="$SCRIPTDIR" workspace select "$env"

terraform -chdir="$SCRIPTDIR" destroy -target="module.gitops_bridge_bootstrap_hub" -var-file="workspaces/${env}.tfvars" -auto-approve
terraform -chdir="$SCRIPTDIR" destroy -target="module.eks_blueprints_addons"       -var-file="workspaces/${env}.tfvars" -auto-approve
terraform -chdir="$SCRIPTDIR" destroy -target="module.eks"                          -var-file="workspaces/${env}.tfvars" -auto-approve
terraform -chdir="$SCRIPTDIR" destroy -target="module.vpc"                          -var-file="workspaces/${env}.tfvars" -auto-approve
terraform -chdir="$SCRIPTDIR" destroy -var-file="workspaces/${env}.tfvars" -auto-approve
