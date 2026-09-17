module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.3.1"

  name                    = var.name
  kubernetes_version      = var.eks_cluster_version
  endpoint_public_access  = true
  endpoint_private_access = false

  authentication_mode = "API_AND_CONFIG_MAP"

  vpc_id     = var.vpc_id
  subnet_ids = var.subnet_ids
  # control_plane_subnet_ids = module.vpc.intra_subnets

  enable_cluster_creator_admin_permissions = true

  compute_config = {
    enabled    = true
    node_pools = ["general-purpose"]
  }
}

data "aws_eks_cluster_auth" "this" {
  name = module.eks.cluster_name
}

output "eks_update_kubeconfig" {
  value = "aws --region ${var.region} eks update-kubeconfig --name ${module.eks.cluster_name} --alias ${module.eks.cluster_name}-${var.region}"
}

output "eks_cluster_name" {
  value = module.eks.cluster_name
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

provider "kubectl" {
  apply_retry_count      = 5
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  load_config_file       = false
  token                  = data.aws_eks_cluster_auth.this.token
}
