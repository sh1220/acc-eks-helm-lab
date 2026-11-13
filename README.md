# ACC 공유 EKS Helm 실습 환경

EKS 클러스터 1개를 5팀(`container-1` ~ `container-5`)이 네임스페이스로 나눠 쓰는 Helm 실습 환경.
개념 설명, 동아리원 사용법, 에러 대처는 Notion 가이드에 있다: **공유 EKS Helm 실습 환경 A to Z**

```
bootstrap/   CI/CD 전제 조건: state S3 버킷, GitHub OIDC, plan/apply 역할 (운영진 PC 에서 1회)
terraform/   VPC · EKS · 노드 그룹 · 애드온 · AWS Load Balancer Controller · gp3 StorageClass
.github/     ci.yml(PR: 검사 + plan 코멘트), apply.yml(main 머지: apply)
k8s/         팀 1개분 매니페스트(team.yaml), 팀 공통 검사 정책(cluster-policy.yaml), ALB 확인용 앱(smoke.yaml)
scripts/     팀 온보딩(kubeconfig 생성), 권한 검증
```

## 구성

| 항목 | 값 |
|---|---|
| 리전 / 클러스터 | `ap-northeast-2` / `sbg-eks` (Kubernetes 1.36) |
| 노드 | `t3.medium` × 2, private 서브넷, prefix delegation으로 노드당 Pod 110 |
| 네트워크 | VPC 10.0.0.0/16, 2AZ, NAT Gateway 1개 |
| 외부 노출 | 공용 ALB 1개 (Ingress `group.name: sbg-demo`, path `/container-N`) |
| 팀 권한 | ServiceAccount 토큰 kubeconfig, ns 안에서만 `edit` |
| 팀 안전장치 | ResourceQuota, LimitRange, Pod Security `baseline`, ValidatingAdmissionPolicy(externalIPs 금지, Ingress는 class `alb`·고정 annotation·`/<자기 ns>` path만) |

팀 quota: requests 300m / 1Gi, limits 1 / 1280Mi, Pod 5, Service 5(LB·NodePort 0), PVC 2 / 5Gi.
LimitRange 기본 limit(200m / 256Mi) × 5 = limits 합계라서, limit을 안 적은 Pod는 정확히 5개까지 뜬다.

## 0. 준비

- 도구: `terraform` ≥ 1.11, `aws` CLI v2, `kubectl`, `helm`
- 동아리 AWS 계정 프로필: `aws configure --profile acc` 후 로컬 명령은 `export AWS_PROFILE=acc` 상태에서 실행

## 1. CI/CD 흐름

homelab-infra 와 같은 방식이다. **인프라 변경은 PR 로 하고, main 머지가 곧 apply 다.**

```
브랜치 → PR ─▶ ci.yml: fmt·validate·tflint·shellcheck · Trivy · terraform plan → PR 에 "CI 리포트" 코멘트
             └ 리뷰 후 squash 머지 ─▶ apply.yml: Trivy CRITICAL 게이트 → terraform apply (결과는 Actions Summary)
```

| 항목 | 값 |
|---|---|
| state | S3 `acc-eks-helm-lab-tfstate-384325768399` / `eks/terraform.tfstate`, `use_lockfile` 잠금, 버전 관리 |
| AWS 인증 | GitHub OIDC. 키를 저장하지 않는다 |
| plan 역할 | `acc-eks-gha-plan`: ReadOnlyAccess, **PR 에서만** assume. EKS 조회 권한(AdminView) |
| apply 역할 | `acc-eks-gha-apply`: AdministratorAccess, **main 브랜치에서만** assume. EKS 관리자 |
| 레포 변수 | `AWS_PLAN_ROLE_ARN`, `AWS_APPLY_ROLE_ARN` |
| Trivy 예외 | `.trivyignore` (EKS public 엔드포인트 등 설계상 필요한 것만, 사유 포함) |

로컬 `terraform plan` 은 언제든 돌려도 된다(`-lock=false` 권장). **로컬 apply 는 CI 가 고장 났을 때만** 한다.

### bootstrap (이미 완료, 다시 할 일 없음)

```bash
cd bootstrap && terraform init && terraform apply     # AWS_PROFILE=acc
gh variable set AWS_PLAN_ROLE_ARN  -b "$(terraform output -json role_arns | jq -r .plan)"
gh variable set AWS_APPLY_ROLE_ARN -b "$(terraform output -json role_arns | jq -r .apply)"
```

bootstrap state 는 `bootstrap/terraform.tfstate` 로컬 파일이다(커밋 안 함). 잃어버려도 리소스는 남아 있고 `terraform import` 로 되살릴 수 있다.

## 1-1. 클러스터 생성·확인 (약 20분, 이때부터 과금)

생성은 이 레포 main 에 `terraform/` 변경이 머지되면 apply.yml 이 한다. 처음 생성은 PR 머지 또는 Actions → apply → Run workflow.

생성 후 운영진 PC 에서:

```bash
$(terraform -chdir=terraform output -raw configure_kubectl)   # 관리자 kubeconfig 등록
kubectl get nodes                              # 2대 Ready
kubectl get nodes -o jsonpath='{.items[*].status.allocatable.pods}'; echo   # 110 110
kubectl -n kube-system get deploy aws-load-balancer-controller              # 2/2
kubectl get storageclass                       # gp3 (default)
```

`gp2`에도 `(default)`가 붙어 있으면 해제: `kubectl annotate storageclass gp2 storageclass.kubernetes.io/is-default-class-`

클러스터 관리자는 `terraform/variables.tf` 의 `cluster_admin_arns` 에 IAM ARN 을 추가하는 PR 로 늘린다.

## 2. 팀 온보딩

```bash
cd ..
./scripts/onboard-teams.sh          # out/container-1..5.kubeconfig 생성
for i in 1 2 3 4 5; do ./scripts/verify-team.sh $i; done   # 전부 OK 여야 함
```

공용 ALB 확인 (1회):

```bash
export KUBECONFIG=out/container-1.kubeconfig
sed s/TEAM/container-1/g k8s/smoke.yaml | kubectl apply -f -
kubectl get ingress smoke -w        # ADDRESS 가 뜨면 Ctrl+C (2~3분)
curl http://<ADDRESS>/container-1/x # hello from container-1
sed s/TEAM/container-1/g k8s/smoke.yaml | kubectl delete -f -
unset KUBECONFIG
```

`out/*.kubeconfig`는 토큰이 평문이다. **팀장에게 DM으로만** 보낸다. ALB 주소와 팀 path(`/container-N`)도 같이 공지한다.

## 3. 운영 중

| 할 일 | 명령 |
|---|---|
| 팀 사용량 | `kubectl get resourcequota -A` |
| ALB 문제 | `kubectl -n kube-system logs deploy/aws-load-balancer-controller --tail=50` |
| 토큰 재발급 (3팀) | `kubectl -n container-3 delete secret team-deployer-token && ./scripts/onboard-teams.sh 3` |
| 실습 없는 기간 노드 0대 | `variables.tf` 의 `node_count` 기본값을 0 으로 바꾸는 PR (컨트롤 플레인·NAT 요금은 계속) |

## 4. 종료 (11/30)

ALB와 EBS는 쿠버네티스가 만든 AWS 리소스라서 **팀 리소스를 먼저 지워야** 고아로 남지 않는다.

```bash
for i in 1 2 3 4 5; do kubectl delete namespace container-$i; done
aws elbv2 describe-load-balancers --region ap-northeast-2 \
  --query "LoadBalancers[?contains(LoadBalancerName,'sbgdemo')].LoadBalancerName"   # [] 가 될 때까지 대기
kubectl get pv                      # 비어 있어야 함
cd terraform && terraform destroy     # 종료는 CI 가 아니라 운영진 PC 에서 (AWS_PROFILE=acc)
```

끝나고 콘솔에서 EC2 로드밸런서 / 볼륨 / 탄력적 IP, VPC NAT 게이트웨이 잔여물이 없는지 확인한다.

## 비용 (대략, 서울 온디맨드)

EKS $0.10/h + t3.medium 2대 약 $0.10/h + NAT 약 $0.06/h + ALB 약 $0.02/h ≈ **하루 $7, 3주 약 $150**.

## 알려진 한계

- apply 역할은 관리자 권한이다. main 에 push 할 수 있는 사람 = AWS 관리자이므로 레포 쓰기 권한을 운영진으로 한정한다.
- 팀 토큰은 만료가 없고 팀 공용이다. 실습 종료 시 네임스페이스 삭제로 회수한다.
- 팀 간 네트워크는 열려 있다(NetworkPolicy 없음).
- 팀 Ingress 의 alb annotation 은 허용 목록(group.name=sbg-demo, scheme=internet-facing, target-type=ip 고정 + `/<ns>` 아래 healthcheck-path)만 통과하고, tls·host 는 쓸 수 없다.
  HTTPS·인증 같은 ALB 기능이 필요하면 `k8s/cluster-policy.yaml` 허용 목록에 추가한다.
