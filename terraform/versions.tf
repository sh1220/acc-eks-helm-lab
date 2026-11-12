terraform {
  required_version = ">= 1.11"

  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 6.0" }
    helm       = { source = "hashicorp/helm", version = "~> 3.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 3.0" }
  }

  # ponytail: 로컬 state. 운영진 여러 명이 apply 하게 되면 S3 backend(use_lockfile)로 옮긴다.
}
