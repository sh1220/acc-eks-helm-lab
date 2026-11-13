# CI/CD 전제 조건. 운영진 PC 에서 1번만 apply 한다 (state 는 이 폴더의 로컬 파일, 커밋하지 않음).
#   - terraform state 용 S3 버킷
#   - GitHub Actions OIDC provider + 역할 2개 (plan: 읽기 전용 / apply: 관리자, main 브랜치만)
terraform {
  required_version = ">= 1.11"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

provider "aws" {
  region = "ap-northeast-2"
  default_tags {
    tags = { Project = "acc-eks-helm-lab", ManagedBy = "terraform-bootstrap" }
  }
}

locals {
  repo = "sh1220/acc-eks-helm-lab"
}

data "aws_caller_identity" "this" {}

################################################################################
# state 버킷
################################################################################

resource "aws_s3_bucket" "state" {
  bucket = "acc-eks-helm-lab-tfstate-${data.aws_caller_identity.this.account_id}"
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration { status = "Enabled" } # state 를 망가뜨려도 이전 버전으로 복구
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

################################################################################
# GitHub Actions OIDC
################################################################################

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_policy_document" "trust" {
  for_each = {
    plan  = "repo:${local.repo}:pull_request"        # PR 에서만
    apply = "repo:${local.repo}:ref:refs/heads/main" # main 브랜치(머지·수동 실행)에서만
  }

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [each.value]
    }
  }
}

resource "aws_iam_role" "gha" {
  for_each             = data.aws_iam_policy_document.trust
  name                 = "acc-eks-gha-${each.key}"
  assume_role_policy   = each.value.json
  max_session_duration = 3600 * 2 # 클러스터 생성·삭제가 20분 넘게 걸린다
}

# plan: 읽기 전용 (plan 은 -lock=false 로 돌아서 state 버킷 쓰기도 필요 없다)
resource "aws_iam_role_policy_attachment" "plan" {
  role       = aws_iam_role.gha["plan"].name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# apply: VPC·EKS·IAM 역할을 만들어야 해서 관리자
resource "aws_iam_role_policy_attachment" "apply" {
  role       = aws_iam_role.gha["apply"].name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

output "state_bucket" {
  value = aws_s3_bucket.state.id
}

output "role_arns" {
  value = { for k, r in aws_iam_role.gha : k => r.arn }
}
