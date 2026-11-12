#!/usr/bin/env bash
# 팀 kubeconfig 가 의도한 권한만 갖는지 확인한다. 사용: ./scripts/verify-team.sh 1
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
i=${1:?팀 번호}
NS=container-$i
OTHER=container-$(( i % 5 + 1 ))
export KUBECONFIG=out/$NS.kubeconfig
fail=0

expect() { # expect <yes|no> <설명> <명령...>
  local want=$1 desc=$2; shift 2
  local got; got=$("$@" 2>/dev/null || true)
  if [ "$got" = "$want" ]; then echo "OK   $desc"; else echo "FAIL $desc (기대 $want, 실제 ${got:-error})"; fail=1; fi
}

expect yes "자기 ns 에 Deployment 생성"   kubectl auth can-i create deployments
expect yes "자기 ns 에 Ingress 생성"      kubectl auth can-i create ingresses.networking.k8s.io
expect yes "자기 ns 에 Secret 생성"       kubectl auth can-i create secrets
expect no  "다른 팀($OTHER) Pod 조회"     kubectl auth can-i get pods -n "$OTHER"
expect no  "ClusterRole 생성"            kubectl auth can-i create clusterroles
expect no  "ResourceQuota 수정"          kubectl auth can-i patch resourcequotas
expect no  "RoleBinding 생성"            kubectl auth can-i create rolebindings
expect no  "노드 조회"                    kubectl auth can-i list nodes

if kubectl run priv-test --image=nginx:1.27 --dry-run=server \
     --overrides='{"spec":{"containers":[{"name":"p","image":"nginx:1.27","securityContext":{"privileged":true}}]}}' \
     >/dev/null 2>&1; then
  echo "FAIL privileged Pod 가 허용됨 (PSA 라벨 확인)"; fail=1
else
  echo "OK   privileged Pod 거부"
fi

reject() { # reject <설명> <매니페스트>: 서버가 거부해야 OK
  if printf '%s\n' "$2" | kubectl apply --dry-run=server -f - >/dev/null 2>&1; then
    echo "FAIL $1 가 허용됨"; fail=1
  else
    echo "OK   $1 거부"
  fi
}

ing() { # ing <path> [추가 annotation 줄]: 팀 Ingress 매니페스트
  printf '%s\n' "apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: verify-ing
  annotations:
    alb.ingress.kubernetes.io/group.name: sbg-demo
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    ${2:-}
spec:
  ingressClassName: alb
  rules: [{ http: { paths: [{ path: $1, pathType: Prefix, backend: { service: { name: x, port: { number: 80 } } } }] } }]"
}

reject "Service externalIPs" "apiVersion: v1
kind: Service
metadata: { name: verify-extip }
spec: { ports: [{ port: 80 }], externalIPs: [1.2.3.4] }"
reject "다른 팀 path(/$OTHER) Ingress"   "$(ing "/$OTHER")"
reject "group.order annotation"          "$(ing "/$NS" "alb.ingress.kubernetes.io/group.order: '-1'")"
reject "conditions annotation"           "$(ing "/$NS" "alb.ingress.kubernetes.io/conditions.x: '[]'")"
reject "healthcheck-path 범위 밖"         "$(ing "/$NS" "alb.ingress.kubernetes.io/healthcheck-path: /$OTHER/health")"
reject "success-codes annotation"        "$(ing "/$NS" "alb.ingress.kubernetes.io/success-codes: abc")"
reject "host 지정"                       "$(ing "/$NS" | sed 's/- http:/- host: evil.example.com\n    http:/; s/rules: \[{ http/rules: [{ host: evil.example.com, http/')"
reject "scheme 변경(internal)"           "$(ing "/$NS" | sed 's/internet-facing/internal/')"

if ing "/$NS" "alb.ingress.kubernetes.io/healthcheck-path: /$NS/health" \
   | kubectl apply --dry-run=server -f - >/dev/null 2>&1; then
  echo "OK   자기 path(/$NS) Ingress 허용"
else
  echo "FAIL 자기 path(/$NS) Ingress 가 거부됨"; fail=1
fi

exit $fail
