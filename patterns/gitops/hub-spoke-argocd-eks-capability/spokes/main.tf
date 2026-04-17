provider "aws" {
  region = local.region
}
data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" {}

data "terraform_remote_state" "cluster_hub" {
  backend = "local"

  config = {
    path = "${path.module}/../hub/terraform.tfstate"
  }
}

################################################################################
# Kubernetes provider — hub cluster (to register spoke as an ArgoCD remote cluster)
################################################################################
provider "kubernetes" {
  host                   = data.terraform_remote_state.cluster_hub.outputs.cluster_endpoint
  cluster_ca_certificate = base64decode(data.terraform_remote_state.cluster_hub.outputs.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = ["eks", "get-token", "--cluster-name", data.terraform_remote_state.cluster_hub.outputs.cluster_name, "--region", data.terraform_remote_state.cluster_hub.outputs.cluster_region]
  }
  alias = "hub"
}

################################################################################
# Kubernetes provider — spoke cluster
################################################################################
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", local.region]
  }
}

locals {
  name        = "spoke-${terraform.workspace}"
  environment = terraform.workspace
  region      = var.region

  cluster_version = var.kubernetes_version

  vpc_cidr = var.vpc_cidr
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  gitops_addons_url      = "${var.gitops_addons_org}/${var.gitops_addons_repo}"
  gitops_addons_basepath = var.gitops_addons_basepath
  gitops_addons_path     = var.gitops_addons_path
  gitops_addons_revision = var.gitops_addons_revision

  gitops_workload_org      = var.gitops_workload_org
  gitops_workload_repo     = var.gitops_workload_repo
  gitops_workload_basepath = var.gitops_workload_basepath
  gitops_workload_path     = var.gitops_workload_path
  gitops_workload_revision = var.gitops_workload_revision
  gitops_workload_url      = "${local.gitops_workload_org}/${local.gitops_workload_repo}"

  addons_metadata = {
    aws_cluster_name = module.eks.cluster_name
    aws_region       = local.region
    aws_account_id   = data.aws_caller_identity.current.account_id
    aws_vpc_id       = module.vpc.vpc_id

    addons_repo_url      = local.gitops_addons_url
    addons_repo_basepath = local.gitops_addons_basepath
    addons_repo_path     = local.gitops_addons_path
    addons_repo_revision = local.gitops_addons_revision

    workload_repo_url      = local.gitops_workload_url
    workload_repo_basepath = local.gitops_workload_basepath
    workload_repo_path     = local.gitops_workload_path
    workload_repo_revision = local.gitops_workload_revision
  }

  tags = {
    Blueprint  = local.name
    GithubRepo = "github.com/gitops-bridge-dev/gitops-bridge"
  }
}

################################################################################
# GitOps Bridge: register spoke as a remote cluster in the hub's ArgoCD
################################################################################
module "gitops_bridge_bootstrap_hub" {
  source = "github.com/gitops-bridge-dev/gitops-bridge-argocd-bootstrap-terraform?ref=v2.0.0"

  # The ArgoCD cluster secret is created on the hub, not the spoke
  providers = {
    kubernetes = kubernetes.hub
  }

  install = false # ArgoCD is not installed on spoke clusters
  cluster = {
    cluster_name = module.eks.cluster_name
    environment  = local.environment
    metadata     = local.addons_metadata
    addons       = { kubernetes_version = local.cluster_version }
    server       = module.eks.cluster_endpoint
    config       = <<-EOT
      {
        "tlsClientConfig": {
          "insecure": false,
          "caData" : "${module.eks.cluster_certificate_authority_data}"
        },
        "awsAuthConfig" : {
          "clusterName": "${module.eks.cluster_name}",
          "roleARN": "${aws_iam_role.spoke.arn}"
        }
      }
    EOT
  }
}

################################################################################
# IAM Role — assumed by ArgoCD hub Pod Identity role to access this spoke cluster
################################################################################
resource "aws_iam_role" "spoke" {
  name               = "${module.eks.cluster_name}-argocd-spoke"
  assume_role_policy = data.aws_iam_policy_document.assume_role_policy.json
  tags               = local.tags
}

data "aws_iam_policy_document" "assume_role_policy" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = [data.terraform_remote_state.cluster_hub.outputs.argocd_iam_role_arn]
    }
  }
}

################################################################################
# EKS Cluster
################################################################################
#tfsec:ignore:aws-eks-enable-control-plane-logging
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name                   = local.name
  cluster_version                = local.cluster_version
  cluster_endpoint_public_access = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Use EKS Access Entries API exclusively — no aws-auth ConfigMap required
  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = true

  # Grant the hub ArgoCD role cluster-admin access via EKS Access Entry.
  # This replaces the deprecated manage_aws_auth_configmap / aws_auth_roles approach.
  access_entries = {
    argocd_hub = {
      principal_arn = aws_iam_role.spoke.arn
      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }

  eks_managed_node_groups = {
    initial = {
      instance_types = ["t3.medium"]

      min_size     = 3
      max_size     = 10
      desired_size = 3
    }
  }

  cluster_addons = {
    vpc-cni = {
      before_compute = true
      most_recent    = true
      configuration_values = jsonencode({
        env = {
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
    }
  }

  tags = local.tags
}

################################################################################
# Supporting Resources
################################################################################
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = local.name
  cidr = local.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]

  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  tags = local.tags
}
