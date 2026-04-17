provider "aws" {
  region = local.region
}
data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" {}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", local.region]
    }
  }
}

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
  name        = "hub-${local.environment}"
  environment = "control-plane"
  region      = var.region

  cluster_version = var.kubernetes_version

  vpc_cidr = var.vpc_cidr
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  gitops_addons_url      = "${var.gitops_addons_org}/${var.gitops_addons_repo}"
  gitops_addons_basepath = var.gitops_addons_basepath
  gitops_addons_path     = var.gitops_addons_path
  gitops_addons_revision = var.gitops_addons_revision

  argocd_namespace = "argocd"

  addons_metadata = {
    aws_cluster_name = module.eks.cluster_name
    aws_region       = local.region
    aws_account_id   = data.aws_caller_identity.current.account_id
    aws_vpc_id       = module.vpc.vpc_id

    argocd_iam_role_arn = aws_iam_role.argocd.arn
    argocd_namespace    = local.argocd_namespace

    addons_repo_url      = local.gitops_addons_url
    addons_repo_basepath = local.gitops_addons_basepath
    addons_repo_path     = local.gitops_addons_path
    addons_repo_revision = local.gitops_addons_revision
  }

  argocd_apps = {
    addons    = file("${path.module}/bootstrap/addons.yaml")
    workloads = file("${path.module}/bootstrap/workloads.yaml")
  }

  tags = {
    Blueprint  = local.name
    GithubRepo = "github.com/gitops-bridge-dev/gitops-bridge"
  }
}

################################################################################
# GitOps Bridge: Bootstrap
# ArgoCD is already installed via the EKS argo-cd cluster add-on, so only the
# cluster secret and ApplicationSets need to be created here (install = false).
################################################################################
module "gitops_bridge_bootstrap" {
  source = "github.com/gitops-bridge-dev/gitops-bridge-argocd-bootstrap-terraform?ref=v2.0.0"

  depends_on = [module.eks]

  install = false # Installed via EKS managed add-on below

  cluster = {
    cluster_name = module.eks.cluster_name
    environment  = local.environment
    metadata     = local.addons_metadata
    addons       = { kubernetes_version = local.cluster_version }
  }
  apps = local.argocd_apps
  argocd = {
    namespace = local.argocd_namespace
  }
}

################################################################################
# ArgoCD IAM Role — Pod Identity (no OIDC circular dependency)
# Allows ArgoCD pods to sts:AssumeRole into spoke clusters.
################################################################################
resource "aws_iam_role" "argocd" {
  name               = "${local.name}-argocd"
  assume_role_policy = data.aws_iam_policy_document.argocd_trust.json
  tags               = local.tags
}

data "aws_iam_policy_document" "argocd_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:eks:${local.region}:${data.aws_caller_identity.current.account_id}:cluster/${local.name}"]
    }
  }
}

resource "aws_iam_policy" "argocd" {
  name        = "${local.name}-argocd"
  description = "Allows ArgoCD hub to assume roles in spoke clusters"
  policy      = data.aws_iam_policy_document.argocd_policy.json
  tags        = local.tags
}

data "aws_iam_policy_document" "argocd_policy" {
  statement {
    effect    = "Allow"
    resources = ["*"]
    actions   = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role_policy_attachment" "argocd" {
  role       = aws_iam_role.argocd.name
  policy_arn = aws_iam_policy.argocd.arn
}

# Pod Identity associations for the ArgoCD service accounts that connect to spokes
resource "aws_eks_pod_identity_association" "argocd_server" {
  cluster_name    = module.eks.cluster_name
  namespace       = local.argocd_namespace
  service_account = "argocd-server"
  role_arn        = aws_iam_role.argocd.arn
}

resource "aws_eks_pod_identity_association" "argocd_application_controller" {
  cluster_name    = module.eks.cluster_name
  namespace       = local.argocd_namespace
  service_account = "argocd-application-controller"
  role_arn        = aws_iam_role.argocd.arn
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

  # Use EKS Access Entries API exclusively (no aws-auth ConfigMap)
  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = true

  eks_managed_node_groups = {
    initial = {
      instance_types = ["t3.medium"]

      min_size     = 3
      max_size     = 10
      desired_size = 3
    }
  }

  cluster_addons = {
    # Required for EKS Pod Identity used by the argo-cd add-on
    eks-pod-identity-agent = {
      most_recent    = true
      before_compute = true
    }
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
    # ArgoCD installed as a native EKS managed add-on
    "argo-cd" = {
      most_recent              = true
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
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
