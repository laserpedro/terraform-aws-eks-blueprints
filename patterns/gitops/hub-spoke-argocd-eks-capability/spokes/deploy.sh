#!/bin/bash
set -uo pipefail

SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
[[ -n "${DEBUG:-}" ]] && set -x

if [[ $# -eq 0 ]] ; then
    echo "No arguments supplied"
    echo "Usage: deploy.sh <environment>"
    echo "Example: deploy.sh dev"
    exit 1
fi
env=$1
echo "Deploying $env with workspaces/${env}.tfvars ..."

if terraform -chdir="$SCRIPTDIR" workspace list | grep -q "$env"; then
    echo "Workspace $env already exists."
else
    terraform -chdir="$SCRIPTDIR" workspace new "$env"
fi

terraform -chdir="$SCRIPTDIR" workspace select "$env"
terraform -chdir="$SCRIPTDIR" init
terraform -chdir="$SCRIPTDIR" apply -var-file="workspaces/${env}.tfvars"
