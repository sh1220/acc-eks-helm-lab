variable "region" {
  type    = string
  default = "ap-northeast-2"
}

variable "aws_profile" {
  description = "동아리 AWS 계정 프로필 (~/.aws/config)"
  type        = string
  default     = "acc"
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
