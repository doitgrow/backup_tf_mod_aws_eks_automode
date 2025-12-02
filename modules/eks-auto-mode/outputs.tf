output "cluster_name" {
  value = module.eks.cluster_name
}

output "openid_connect_provider_url" {
  value = module.eks.cluster_oidc_issuer_url
}

output "openid_connect_provider_arn" {
  value = module.eks.oidc_provider_arn
}
