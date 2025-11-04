variable "name" {
  type = string
}
variable "region" {
  type    = string
  default = "ap-northeast-2"
}
variable "vpc_id" {
  type = string
}
variable "vpc_cidr" {
  type = string
}
variable "private_subnets" {
  type = list(string)
}
variable "eks_cluster_version" {
  type    = string
  default = "1.34"
}
variable "domain" {
  type    = string
  default = ""
}
variable "efs_throughput_mode" {
  type    = string
  default = "bursting"
}
variable "gpu_nodepool_capacity_type" {
  type    = list(string)
  default = ["spot", "on-demand"]
}

variable "gpu_nodepool_instance_family" {
  type    = list(string)
  default = ["g6e", "g6", "g5g", "p4de", "p4d"] # H200: "p5e", H100: "p5"
}

locals {
  account_id = data.aws_caller_identity.current.account_id
}

data "aws_caller_identity" "current" {}



