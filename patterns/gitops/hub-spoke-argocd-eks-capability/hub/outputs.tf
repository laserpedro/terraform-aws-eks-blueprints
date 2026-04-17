output "configure_kubectl" {
  description = "Configure kubectl: make sure you're logged in with the correct AWS profile and run the following command to update your kubeconfig"
  value       = "aws eks --region ${local.region} update-kubeconfig --name ${module.eks.cluster_name} --alias hub"
}

output "argocd_server_url" {
  description = "URL of the ArgoCD server deployed by the EKS capability"
  value       = module.argocd_eks_capability.argocd_server_url
}

output "argocd_iam_role_arn" {
  description = "IAM Role ARN of the ArgoCD EKS capability — used in spoke cluster trust policies"
  value       = module.argocd_eks_capability.iam_role_arn
}

output "cluster_name" {
  description = "Hub cluster name"
  value       = module.eks.cluster_name
}
output "cluster_endpoint" {
  description = "Hub cluster endpoint"
  value       = module.eks.cluster_endpoint
}
output "cluster_certificate_authority_data" {
  description = "Hub cluster certificate authority data"
  value       = module.eks.cluster_certificate_authority_data
}
output "cluster_region" {
  description = "Hub cluster region"
  value       = local.region
}
