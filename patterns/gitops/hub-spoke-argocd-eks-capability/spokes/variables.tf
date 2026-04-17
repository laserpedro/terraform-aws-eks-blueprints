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
