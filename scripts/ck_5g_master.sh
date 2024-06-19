#!/bin/bash
#set -u
#set -x

SCRIPTDIR=$(dirname "$0")
WORKINGDIR='/local/repository'
username=$(id -nu)
HOME=/users/$(id -un)
usergid=$(id -ng)
experimentid=$(hostname|cut -d '.' -f 2)
projectid=$usergid

sudo chown ${username}:${usergid} ${WORKINGDIR}/ -R
cd $WORKINGDIR
# Redirect output to log file
exec >> ${WORKINGDIR}/deploy.log
exec 2>&1

KUBEHOME="${WORKINGDIR}/kube"
mkdir -p $KUBEHOME
export KUBECONFIG=$KUBEHOME/admin.conf

# make SSH shells play nice
sudo chsh -s /bin/bash $username
echo "export KUBECONFIG=${KUBECONFIG}" > $HOME/.profile

# add repositories
# Kubernetes
sudo apt-get install -y apt-transport-https ca-certificates curl gpg
sudo mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
# Docker
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Update apt lists
sudo apt-get update

# Install pre-reqs
sudo apt-get -y install build-essential libffi-dev python python-dev  \
python-pip automake autoconf libtool indent vim tmux ctags xgrep moreutils \
python3-numpy python3-pandas python3-matplotlib


# docker

cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system

wget https://github.com/opencontainers/runc/releases/download/v1.1.3/runc.amd64
sudo install -m 755 runc.amd64 /usr/local/sbin/runc
wget https://github.com/containernetworking/plugins/releases/download/v1.1.1/cni-plugins-linux-amd64-v1.1.1.tgz
sudo mkdir -p /opt/cni/bin
sudo tar Cxzvf /opt/cni/bin cni-plugins-linux-amd64-v1.1.1.tgz

#wget https://github.com/containerd/containerd/releases/download/v1.6.8/containerd-1.6.8-linux-amd64.tar.gz
#sudo tar Cxzvf /usr/local containerd-1.6.8-linux-amd64.tar.gz
sudo apt-get install -y containerd.io
sudo mkdir -p /etc/containerd/
containerd config default | sudo tee /etc/containerd/config.toml
sudo sed -i 's/            SystemdCgroup = false/            SystemdCgroup = true/' /etc/containerd/config.toml
sudo curl -L https://raw.githubusercontent.com/containerd/containerd/main/containerd.service -o /etc/systemd/system/containerd.service
sudo systemctl restart containerd
sudo systemctl daemon-reload
sudo systemctl enable --now containerd

sudo systemctl status containerd

echo " install for containerd finished, -      ------------------------------------------------------------------------------------------------------"

# learn from this: https://blog.csdn.net/yan234280533/article/details/75136630
# more info should see: https://kubernetes.io/docs/setup/independent/create-cluster-kubeadm/
sudo apt-get update
# sudo apt-get -y install kubelet=1.25.5-1.1 kubeadm=1.25.1-1.1 kubectl=1.25.1-1.1 kubernetes-cni golang-go jq
sudo apt-get -y install kubelet kubeadm kubectl kubernetes-cni golang-go jq
sudo apt-mark hold kubelet kubeadm kubectl

sudo modprobe br_netfilter
sudo swapoff -a 
sudo sed -i.bak -r 's/(.+ swap .+)/#\1/' /etc/fstab
sudo kubeadm config migrate --old-config /local/repository/config/kubeadm-config.yaml --new-config /local/repository/config/kubeadm-config.yaml
sudo kubeadm init --config=config/kubeadm-config.yaml --v=5

# result will be like:  kubeadm join 155.98.36.111:6443 --token i0peso.pzk3vriw1iz06ruj --discovery-token-ca-cert-hash sha256:19c5fdee6189106f9cb5b622872fe4ac378f275a9d2d2b6de936848215847b98

# allow sN to log in with shared key
# see http://docs.powderwireless.net/advanced-topics.html
geni-get key > ${HOME}/.ssh/id_rsa
chmod 600 ${HOME}/.ssh/id_rsa
ssh-keygen -y -f ${HOME}/.ssh/id_rsa > ${HOME}/.ssh/id_rsa.pub
grep -q -f ${HOME}/.ssh/id_rsa.pub ${HOME}/.ssh/authorized_keys || cat ${HOME}/.ssh/id_rsa.pub >> ${HOME}/.ssh/authorized_keys

# https://github.com/kubernetes/kubernetes/issues/44665
sudo cp /etc/kubernetes/admin.conf $KUBEHOME/
sudo chown ${username}:${usergid} $KUBEHOME/admin.conf

# Install Flannel. See https://github.com/coreos/flannel
sudo kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml
sudo kubectl get daemonset -n kube-flannel kube-flannel-ds -o json | jq '.spec.template.spec.containers[0].args += ["--iface-regex=192\\.168\\..*\\..*"]' | sudo kubectl replace -f -

# use this to enable autocomplete
source <(kubectl completion bash)

# kubectl get nodes --kubeconfig=${KUBEHOME}/admin.conf -s https://155.98.36.111:6443

# Deploy Prometheus
sudo kubectl create -f config/test/prometheus.yaml

# Deploy Grafana
sudo kubectl create -f config/test/grafana.yaml
sudo kubectl create configmap corekube-grafana-dashboards --namespace=grafana --from-file=config/test/dashboards/

# We should now port-forward the dashboard service which is at port 3000 locally,
# but we'll do that later since it'll take a few seconds to get everything ready
# after applying the YAML file, and it's better to do other things (like doing
# other installations) in parallel.

# jid for json parsing.
export GOPATH=${WORKINGDIR}/go/gopath
mkdir -p $GOPATH
export PATH=$PATH:$GOPATH/bin
sudo go get -u github.com/simeji/jid/cmd/jid
sudo go build -o /usr/bin/jid github.com/simeji/jid/cmd/jid

# install static cni plugin
sudo go get -u github.com/containernetworking/plugins/plugins/ipam/static
sudo go build -o /opt/cni/bin/static github.com/containernetworking/plugins/plugins/ipam/static

# install helm
echo "Installing Helm"
wget https://get.helm.sh/helm-v3.1.0-linux-amd64.tar.gz
tar xf helm-v3.1.0-linux-amd64.tar.gz
sudo cp linux-amd64/helm /usr/local/bin/helm

source <(helm completion bash)

# run port-forward to make the dashboard portal accessible from outside
echo "Port-forwarding port 80 of dashboard service at public port 12345..."
# Make sure the dashboard pod is ready before port-forwarding, since otherwise
# kubectl port-forward will fail. This adds a slight delay to the setup but it
# should be very negligible because we've moved the waiting/port-forwarding to
# after the helm installation above, which should give it enough time to start
# up in the background. If not, we will wait up to 10 minutes instead of the
# default 30 seconds.
kubectl wait -n grafana --for=condition=ready pod --all --timeout=10m
sudo kubectl port-forward services/corekube-grafana -n grafana --address='0.0.0.0' 12345:3000 &

# Install metrics-server for HPA
# (Old method)
#helm repo add stable https://kubernetes-charts.storage.googleapis.com/
#helm install --namespace=kube-system metrics-server stable/metrics-server -f ${WORKINGDIR}/config/metrics-server-values.yaml
helm repo add stable https://charts.bitnami.com/bitnami
helm install --namespace=kube-system metrics-server bitnami/metrics-server -f ${WORKINGDIR}/config/metrics-server-values.yaml

# Wait till the slave nodes get joined and update the kubelet daemon successfully
# number of slaves + 1 master
node_cnt=$(($(/local/repository/scripts/geni-get-param ck_nodes) + 1))
# 1 node per line - header line
joined_cnt=$(( `kubectl get nodes | wc -l` - 1 ))
echo "Total nodes: $node_cnt Joined: ${joined_cnt}"
while [ $node_cnt -ne $joined_cnt ]
do 
    joined_cnt=$(( `kubectl get nodes |wc -l` - 1 ))
    sleep 1
done
echo "All nodes joined"

# Display for the end-user where the dashboard is, using our public hostname
echo "Grafana is ready at: http://$(hostname --fqdn):12345"

# Also make the link display on every SSH login too, for convenience:
BOLD_RESET="\033[22m"
BOLD="\033[1m"
BLUE="\033[34m"
RED="\033[31m"
RESET="\033[0m"

cat <<ASD >> /users/${username}/.ssh/rc
test -z \$SSH_TTY && return # Don't run when not-interactive like SCP
echo "${BLUE}==================${RESET}"
echo "${BLUE}This is the ${BOLD}CoreKube${BOLD_RESET} Kubernetes cluster ${BOLD}master node${BOLD_RESET}."
echo "${BOLD}CoreKube Dashboard:${RESET} http://$(hostname --fqdn):12345"
echo "${BLUE}==================${RESET}"
ASD

# Deploy metrics server
sudo kubectl create -f config/test/metrics-server.yaml
# Deploy Test Core
sudo kubectl create -f config/test/5G/deployment.yaml

# Install tshark
sudo add-apt-repository -y ppa:wireshark-dev/stable
sudo apt update
export DEBIAN_FRONTEND=noninteractive
sudo apt-get -yq install tshark

# Start logging the HPA every second
config/test/loghpa.sh &

# Log all the traffic on the CK master node
#sudo tcpdump -i any -w ~/tcpdump.pcap &

# to know how much time it takes to instantiate everything.
echo "Setup DONE!"
date