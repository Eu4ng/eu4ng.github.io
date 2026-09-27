# Proxmox 클러스터의 QDevice 서버(corosync-qnetd). 두 노드짜리 클러스터에 세 번째 표를 줍니다. 서울 NAS 에서 돌립니다(stacks/seoul/qnetd).
# pvecm qdevice setup 이 ssh(root)로 이 컨테이너에 붙어 인증서를 만들고 서명하므로 sshd 를 함께 띄웁니다.
# Proxmox VE 9 와 같은 Debian trixie 의 corosync-qnetd 를 씁니다. 태그는 QNETD_VERSION 을 씁니다 (.github/workflows/build-qnetd.yml).
ARG QNETD_VERSION=3.0.3-2
FROM debian:trixie-slim
ARG QNETD_VERSION
RUN apt-get update \
    && apt-get install -y --no-install-recommends corosync-qnetd=${QNETD_VERSION} openssh-server \
    && rm -rf /var/lib/apt/lists/* \
    # 설치 스크립트가 만든 인증서 DB 와 ssh 호스트 키는 버립니다. 이미지에 CA 키가 들어가지 않게, 처음 실행할 때 볼륨에 만듭니다
    && rm -rf /etc/corosync/qnetd/nssdb /etc/ssh/ssh_host_* \
    && mkdir -p /run/sshd
COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
