provider "aws" {
  region = var.region

  default_tags {
    tags = { Project = "acc-eks-helm-lab", ManagedBy = "terraform" }
  }
}

locals {
  # helm/kubernetes provider 가 EKS 에 붙을 때 쓰는 토큰 발급 명령 (로컬은 AWS_PROFILE, CI 는 OIDC 자격증명)
  eks_exec = {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = local.eks_exec.api_version
    command     = local.eks_exec.command
    args        = local.eks_exec.args
  }
}

provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec                   = local.eks_exec
  }
}
