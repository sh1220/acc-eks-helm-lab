terraform {
  required_version = ">= 1.11"

  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 6.0" }
    helm       = { source = "hashicorp/helm", version = "~> 3.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 3.0" }
  }

  # 버킷은 bootstrap/ 이 만든다. 로컬에서 돌릴 때는 AWS_PROFILE=acc
  backend "s3" {
    bucket       = "acc-eks-helm-lab-tfstate-384325768399"
    key          = "eks/terraform.tfstate"
    region       = "ap-northeast-2"
    use_lockfile = true
  }
}
