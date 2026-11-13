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
  description = "노드 수. 실습 없는 기간에는 0으로 내려 노드 요금을 아낀다"
  type        = number
  default     = 2
}

variable "cluster_admin_arns" {
  description = "클러스터 관리자 권한을 줄 운영진 IAM (CI 역할은 main.tf 에서 따로 등록)"
  type        = list(string)
  default     = ["arn:aws:iam::384325768399:user/sunghyun"]
}
