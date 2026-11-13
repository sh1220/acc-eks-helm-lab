data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

# bootstrap/ 이 만든 GitHub Actions 역할
data "aws_iam_role" "gha" {
  for_each = toset(["plan", "apply"])
  name     = "acc-eks-gha-${each.key}"
}

locals {
  admin_policy = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  # plan 이 helm_release(release 정보가 kube-system Secret 에 있음)와 StorageClass(클러스터 범위)를 읽어야 해서
  # Secret 까지 보이는 AdminView 를 쓴다. plan 역할은 이 레포의 PR 에서만 assume 되고, PR 을 만들 수 있는 사람은
  # main 에 push 해 apply(관리자) 역할도 쓸 수 있으므로 권한이 늘어나지는 않는다.
  # main 브랜치 보호(리뷰 필수)를 켜면 이 전제가 깨지므로 그때 plan 역할 범위를 다시 줄인다.
  view_policy = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminViewPolicy"

  access_entries = merge(
    { for arn in concat(var.cluster_admin_arns, [data.aws_iam_role.gha["apply"].arn]) : arn => {
      principal_arn       = arn
      policy_associations = { admin = { policy_arn = local.admin_policy, access_scope = { type = "cluster" } } }
    } },
    { (data.aws_iam_role.gha["plan"].arn) = {
      principal_arn       = data.aws_iam_role.gha["plan"].arn
      policy_associations = { view = { policy_arn = local.view_policy, access_scope = { type = "cluster" } } }
    } },
  )

  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 2)
}

################################################################################
# VPC: public(ALB, NAT) / private(노드) 서브넷 2AZ, NAT 1개
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.7"

  name = var.cluster_name
  cidr = local.vpc_cidr
  azs  = local.azs

  private_subnets = [for i, _ in local.azs : cidrsubnet(local.vpc_cidr, 4, i)]      # 10.0.0.0/20, 10.0.16.0/20
  public_subnets  = [for i, _ in local.azs : cidrsubnet(local.vpc_cidr, 8, i + 48)] # 10.0.48.0/24, 10.0.49.0/24

  enable_nat_gateway = true
  single_nat_gateway = true # ponytail: NAT 1개(비용 절약). 그 AZ 장애 시 노드 외부 통신 끊김

  # AWS Load Balancer Controller 가 ALB 놓을 서브넷을 찾는 태그
  public_subnet_tags  = { "kubernetes.io/role/elb" = 1 }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1 }
}

################################################################################
# EKS 클러스터 + 노드 그룹
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.29"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  # 운영진/동아리원 PC 에서 접속하므로 public 엔드포인트
  endpoint_public_access = true

  # 누가 apply 하든(운영진 PC / CI) 같은 권한이 되도록 생성자 자동 권한 대신 명시적으로 등록
  enable_cluster_creator_admin_permissions = false
  access_entries                           = local.access_entries

  # Secret 암호화 KMS 키 관리자. 비워 두면 "terraform 을 실행한 주체"가 들어가서
  # CI(plan/apply 역할)·운영진 PC 중 누가 돌리느냐에 따라 매번 diff 가 생긴다 → 고정
  kms_key_administrators = concat(var.cluster_admin_arns, [data.aws_iam_role.gha["apply"].arn])

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  addons = {
    vpc-cni = {
      before_compute = true
      # prefix delegation: t3.medium 노드당 Pod 상한 17 → 110
      configuration_values = jsonencode({ env = { ENABLE_PREFIX_DELEGATION = "true" } })
    }
    eks-pod-identity-agent = { before_compute = true }
    coredns                = {}
    kube-proxy             = {}
    aws-ebs-csi-driver = {
      pod_identity_association = [{
        role_arn        = module.ebs_csi_pod_identity.iam_role_arn
        service_account = "ebs-csi-controller-sa"
      }]
    }
  }

  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = [var.node_instance_type]

      min_size     = 0
      max_size     = 4
      desired_size = var.node_count

      # prefix delegation 과 짝: kubelet 의 Pod 상한을 110 으로
      cloudinit_pre_nodeadm = [{
        content_type = "application/node.eks.aws"
        content      = <<-EOT
          ---
          apiVersion: node.eks.aws/v1alpha1
          kind: NodeConfig
          spec:
            kubelet:
              config:
                maxPods: 110
        EOT
      }]
    }
  }
}

################################################################################
# Pod Identity: EBS CSI 드라이버, AWS Load Balancer Controller 의 AWS 권한
################################################################################

module "ebs_csi_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.10"

  name                      = "${var.cluster_name}-ebs-csi"
  attach_aws_ebs_csi_policy = true
}

module "lb_controller_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.10"

  name                            = "${var.cluster_name}-lb-controller"
  attach_aws_lb_controller_policy = true

  associations = {
    this = {
      cluster_name    = module.eks.cluster_name
      namespace       = "kube-system"
      service_account = "aws-load-balancer-controller"
    }
  }
}

################################################################################
# 클러스터 공용 설치물: AWS Load Balancer Controller, 기본 StorageClass(gp3)
################################################################################

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"

  set = [
    { name = "clusterName", value = module.eks.cluster_name },
    { name = "region", value = var.region },
    { name = "vpcId", value = module.vpc.vpc_id },
    { name = "serviceAccount.name", value = "aws-load-balancer-controller" },
  ]

  depends_on = [module.eks, module.lb_controller_pod_identity]
}

resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name        = "gp3"
    annotations = { "storageclass.kubernetes.io/is-default-class" = "true" }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  volume_binding_mode    = "WaitForFirstConsumer" # Pod 가 뜨는 노드의 AZ 에 디스크 생성
  reclaim_policy         = "Delete"               # PVC 삭제 시 EBS 도 삭제
  allow_volume_expansion = true

  parameters = {
    type      = "gp3"
    encrypted = "true"
  }

  depends_on = [module.eks]
}
