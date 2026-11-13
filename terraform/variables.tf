variable "region" {
  type    = string
  default = "ap-northeast-2"
}

variable "cluster_name" {
  type    = string
  default = "sbg-eks"
}

variable "kubernetes_version" {
  type    = string
  default = "1.36"
}

variable "node_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "node_count" {
  # EKS 모듈이 desired_size 변경을 무시한다(ignore_changes). 생성 이후 노드 수 조절은 README 의 aws eks update-nodegroup-config 로 한다
  description = "노드 그룹을 처음 만들 때의 노드 수"
  type        = number
  default     = 2
}

variable "cluster_admin_arns" {
  description = "클러스터 관리자 권한을 줄 운영진 IAM (CI 역할은 main.tf 에서 따로 등록)"
  type        = list(string)
  default     = ["arn:aws:iam::384325768399:user/sunghyun"]
}
