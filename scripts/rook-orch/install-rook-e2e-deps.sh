#!/usr/bin/env bash

set -ex

on_error() {
    if [ "$1" != "0" ]; then
        printf "\n\nERROR $1 thrown on line $2\n\n"
        printf "\n\nCollecting info...\n\n"
        sudo journalctl --since "10 min ago" --no-tail --no-pager -x
        printf "\n\nERROR: displaying containers' logs:\n\n"
        docker ps -aq | xargs docker logs
        printf "\n\nTEST FAILED.\n\n"
    fi
}

trap 'on_error $? $LINENO' ERR

# Install required deps.
DISTRO="$(lsb_release -cs)"
sudo apt install -y libvirt-daemon-system libvirt-daemon-driver-qemu qemu-kvm libvirt-clients runc python3
sudo apt update -y
sudo apt install -y python3-pip
sudo pip3 install behave

sudo usermod -aG libvirt $(id -un)
newgrp libvirt  # Avoid having to log out and log in for group addition to take effect.
sudo systemctl enable --now libvirtd

if [[ $(command -v docker) == '' ]]; then
    # Set up docker official repo and install docker.
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo \
        "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
        ${DISTRO} stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt update -y
    sudo apt install -y docker-ce docker-ce-cli containerd.io
fi
sudo groupadd docker || true
sudo usermod -aG docker $(id -un)
sudo systemctl start docker
sudo chgrp "$(id -un)" /var/run/docker.sock

docker info
docker container prune -f

KCLI_CONFIG_DIR="${HOME}/.kcli"
mkdir -p ${KCLI_CONFIG_DIR}
if [[ ! -f "${KCLI_CONFIG_DIR}/id_rsa" ]]; then
    ssh-keygen -t rsa -q -f "${KCLI_CONFIG_DIR}/id_rsa" -N ""
fi

: ${KCLI_CONTAINER_IMAGE:='quay.io/karmab/kcli:22.10'}

docker pull ${KCLI_CONTAINER_IMAGE}

echo "#!/usr/bin/env bash

docker run --net host --security-opt label=disable \
    -v ${KCLI_CONFIG_DIR}:/root/.kcli \
    -v ${PWD}:/workdir \
    -v /var/lib/libvirt/images:/var/lib/libvirt/images \
    -v /var/run/libvirt:/var/run/libvirt \
    -v /var/tmp:/ignitiondir \
    ${KCLI_CONTAINER_IMAGE} \""'${@}'"\"
" | sudo tee /usr/local/bin/kcli
sudo chmod +x /usr/local/bin/kcli


# KCLI cleanup function can be found here: https://github.com/ceph/ceph/blob/main/src/pybind/mgr/rook/ci/start-cluster.sh
sudo mkdir -p /var/lib/libvirt/images/ceph-rook
kcli delete plan cephkube -y || true
kcli create pool -p /var/lib/libvirt/images/ceph-rook cephkubePool
