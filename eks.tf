module "eks_auto_mode" {
  source                       = "./modules/eks-auto-mode"
  name                         = var.name
  region                       = var.region
  eks_cluster_version          = var.eks_cluster_version
  vpc_id                       = var.vpc_id
  vpc_cidr                     = var.vpc_cidr
  subnet_ids                   = var.private_subnets
  domain                       = var.domain
  efs_file_system_id           = aws_efs_file_system.this.id
  gpu_nodepool_capacity_type   = var.gpu_nodepool_capacity_type
  gpu_nodepool_instance_family = var.gpu_nodepool_instance_family
  pod_subnet_ids               = var.pod_subnet_ids
  pod_security_group_ids       = var.pod_security_group_ids
}
