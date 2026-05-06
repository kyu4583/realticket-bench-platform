# 06-vm-environment — VM 고정 인프라

본 영역은 VM(`192.168.138.2`)의 고정 인프라만 책임한다 — Docker Swarm 구성·Redis Sentinel·Prometheus(`:9090`)·Grafana(`:3000`)·cAdvisor·SSH 키. 벤치마크 시점 변동(이미지 swap·`docker stack` restart)은 [02-orchestration](../02-orchestration/README.md) 책임이다.

두 영역의 경계 판별식: **"벤치마크 시점에 바뀌는가"** — 바뀌지 않는 것이 본 영역, 바뀌는 것이 02 책임.

---

## VM 접속

| 항목 | 값 |
|------|----|
| IP | `192.168.138.2` |
| SSH alias | `ssh VM_ubuntu` |
| SSH 전체 명령 | `ssh kyu4583@192.168.138.2 -i ~/.ssh/vm_ubuntu_key` |
| Docker Swarm | manager 노드 1개, `realticket` stack |

---

## 인프라 컴포넌트

| # | 컴포넌트 | 위치/접근 | 책임 (1줄) |
|---|---------|----------|-----------|
| 1 | **Docker Swarm** | `ssh VM_ubuntu` → `docker node ls` | manager 노드 1개 + `realticket` stack 운영 |
| 2 | **Redis Sentinel HA** | Swarm 내 `realticket_sentinel-1..N` | Redis master failover (RealTicket BE 좌석 점유·SSE 세션 저장) |
| 3 | **Prometheus** | `http://192.168.138.2:9090` | 메트릭 시계열 (분석의 1차 출처). cAdvisor·node-exporter·nest custom counter 스크랩 |
| 4 | **Grafana** | `http://192.168.138.2:3000` | 운영자 대시보드 (자동화에서는 부수 자료). login page 도달까지만 보장 |
| 5 | **cAdvisor** | Swarm 내 service. Prometheus가 스크랩 | 컨테이너별 CPU/Memory/Network 메트릭 → Prometheus |
| 6 | **SSH 진입** | `ssh VM_ubuntu` alias | 모든 VM 명령의 단일 진입점 (Lock #1 VM 영역 변형). 키 파일: 로컬 `~/.ssh/vm_ubuntu_key` (절대 commit X) |

---

## 헬스체크

```bash
# 1. Docker Swarm 노드 상태 (manager Ready Active 확인)
ssh VM_ubuntu "docker node ls"

# 2. Prometheus 헬스체크 (HTTP 200 + "Prometheus Server is Healthy." 응답)
curl -sf 'http://192.168.138.2:9090/-/healthy' && echo OK

# 3. SSH 진입 확인
ssh VM_ubuntu 'echo ok'
```

추가 확인 명령:

```bash
# Stack 컴포넌트 인벤토리
ssh VM_ubuntu "docker stack ps realticket"

# Sentinel master 확인
ssh VM_ubuntu 'docker exec -it $(docker ps -q -f name=sentinel-1) redis-cli -p 26379 SENTINEL masters'

# Grafana login page 확인
curl -sf 'http://192.168.138.2:3000/login' >/dev/null && echo OK
```

---

## 이상 발견 시 AI 행동

| 이상 유형 | AI 행동 |
|----------|---------|
| Swarm 이상 | 사용자에게 보고 후 매니페스트 실행 중단 (`die`). AI가 Swarm 재구성 시도 금지 |
| Prometheus 미응답 | 사용자에게 보고 후 중단. prom_query 결과가 무의미하기 때문 |
| SSH 불가 | 사용자에게 보고 후 중단. 모든 VM 조작의 전제 조건 |

---

## AI가 본 영역을 수정하는 시점

- **인프라 컴포넌트 표 갱신** — Swarm 노드 추가·Sentinel quorum 재구성·Prometheus retention 변경이 발생한 경우. 변경 commit 메시지에 변경 사유 + 영향 영역 명시 필수
- **02-orchestration cross-check** — 인프라 변경 시 `areas/02-orchestration/README.md` stack restart 절차가 영향을 받는지 확인

m1 동안 인프라 변경 없음 — 본 파일은 현재 상태 스냅샷.

---

## 행동 금지

- AI가 Swarm 재구성·Sentinel quorum 변경·Prometheus 재설치를 직접 시도 금지
- SSHFS·VirtualBox GUI·매크로 사용 금지 (Lock #1 — `ssh VM_ubuntu`만)
- 이미지 swap·stack restart를 본 영역에서 수행 금지 (02-orchestration 책임)
- `~/.ssh/vm_ubuntu_key` git commit 절대 금지

---

## AI 작업 지침

### 매니페스트 실행 전 인프라 사전 검증 순서

1. `ssh VM_ubuntu "docker node ls"` — manager Ready Active 확인
2. `curl -sf 'http://192.168.138.2:9090/-/healthy' && echo OK` — Prometheus 헬스체크
3. `ssh VM_ubuntu 'echo ok'` — SSH 진입 확인

셋 모두 정상이면 매니페스트 실행 진행. 하나라도 실패하면 사용자에게 보고 후 중단.

### 변동 vs 고정 분리

- **고정 (본 영역):** Swarm 자체 존재·Sentinel quorum·Prom/Grafana 프로세스·cAdvisor 스크랩·SSH 키
- **변동 (02-orchestration):** 이미지 swap·stack force-restart·stack 재시작 절차·iter 간 cooldown
