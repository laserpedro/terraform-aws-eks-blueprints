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

  argocd_namespace = "argocd"

  tags = {
    Blueprint  = local.name
    GithubRepo = "github.com/aws-ia/terraform-aws-eks-blueprints"
  }
}

################################################################################
# ArgoCD Cluster Secret — registers this spoke with the hub's ArgoCD instance.
# Created in the hub cluster's argocd namespace so ArgoCD discovers it on startup.
################################################################################
resource "kubernetes_secret" "argocd_cluster" {
  provider = kubernetes.hub

  metadata {
    name      = module.eks.cluster_name
    namespace = local.argocd_namespace
    labels = {
      "argocd.argoproj.io/secret-type" = "cluster"
    }
    annotations = {
      "environment" = local.environment
    }
  }

  type = "Opaque"

  data = {
    name   = module.eks.cluster_name
    server = module.eks.cluster_endpoint
    config = jsonencode({
      tlsClientConfig = {
        insecure = false
        caData   = module.eks.cluster_certificate_authority_data
      }
      awsAuthConfig = {
        clusterName = module.eks.cluster_name
        roleARN     = aws_iam_role.spoke.arn
      }
    })
  }
}

################################################################################
# Spoke IAM Role
# Assumed by the hub's ArgoCD capability IAM role to authenticate to this cluster.
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
  version = "~> 21.0"

  name                   = local.name
  kubernetes_version     = local.cluster_version
  endpoint_public_access = true

  # Use EKS Access Entries API exclusively — no aws-auth ConfigMap required
  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = true

  # Grant the hub ArgoCD capability role cluster-admin access via EKS Access Entry.
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

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

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
  version = "~> 6.0"

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
