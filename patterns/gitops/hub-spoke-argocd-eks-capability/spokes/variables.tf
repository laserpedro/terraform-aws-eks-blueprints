variable "region" {
  description = "AWS region"
  type        = string
}
variable "vpc_cidr" {
  description = "VPC CIDR"
  type        = string
}
variable "kubernetes_version" {
  description = "EKS version"
  type        = string
}

# Workloads Git
variable "gitops_workload_org" {
  description = "Git repository org/user contains for workloads"
  type        = string
  default     = "https://github.com/argoproj"
}
variable "gitops_workload_repo" {
  description = "Git repository contains for workloads"
  type        = string
  default     = "argocd-example-apps"
}
variable "gitops_workload_revision" {
  description = "Git repository revision/branch/ref for workloads"
  type        = string
  default     = "master"
}
variable "gitops_workload_basepath" {
  description = "Git repository base path for workloads"
  type        = string
  default     = ""
}
variable "gitops_workload_path" {
  description = "Git repository path for workloads"
  type        = string
  default     = "helm-guestbook"
}
