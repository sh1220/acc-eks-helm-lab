#!/usr/bin/env bash
# 팀 네임스페이스·quota·권한을 만들고 팀별 kubeconfig 를 out/ 에 생성한다.
# 사용: ./scripts/onboard-teams.sh            (1~5팀)
#       ./scripts/onboard-teams.sh 3          (3팀만, 토큰 재발급 시)
# 전제: 현재 kubectl context 가 클러스터 관리자 (terraform output configure_kubectl)
set -euo pipefail
cd "$(dirname "$0")/.."

TEAMS=${*:-1 2 3 4 5}
SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CA=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
mkdir -p out

for i in $TEAMS; do
  NS=container-$i
  sed "s/TEAM/$NS/g" k8s/team.yaml | kubectl apply -f -

  # 토큰은 컨트롤러가 몇 초 뒤에 채운다
  TOKEN=""
  for _ in $(seq 1 30); do
    TOKEN=$(kubectl -n "$NS" get secret team-deployer-token -o jsonpath='{.data.token}' | base64 -d)
    [ -n "$TOKEN" ] && break
    sleep 1
  done
  [ -n "$TOKEN" ] || { echo "$NS: 토큰이 생성되지 않음" >&2; exit 1; }

  umask 077
  cat > "out/$NS.kubeconfig" <<KUBECONFIG
apiVersion: v1
kind: Config
clusters:
- name: sbg-eks
  cluster:
    server: $SERVER
    certificate-authority-data: $CA
users:
- name: $NS
  user:
    token: $TOKEN
contexts:
- name: $NS
  context:
    cluster: sbg-eks
    namespace: $NS
    user: $NS
current-context: $NS
KUBECONFIG
  echo "out/$NS.kubeconfig 생성"
done
