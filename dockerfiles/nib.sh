#!/bin/bash
# Script to configure Ubuntu system based on ubuntu_only Ansible role
# This script executes all tasks from the ubuntu_only role

set -euxo pipefail

# Color output for better readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

OFFLINE_MODE_ENABLED=false
KUBERNETES_VERSION=1.34.1
KUBERNETES_MAJOR_MINOR=1.34
KUBERNETES_DEB_GPG_KEY_URL="https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_MAJOR_MINOR}/deb/Release.key"
KUBERNETES_DEB_REPOSITORY_URL="https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_MAJOR_MINOR}/deb/"
KUBERNETES_DEB_RELEASE_NAME=/
KUBERNETES_DEB_VERSION=${KUBERNETES_VERSION}-1.1
CRITOOLS_DEB=${KUBERNETES_MAJOR_MINOR}.0-1.1

# Containerd Configuration
CONTAINERD_VERSION=2.1.4
CONTAINERD_TARGET_ARCH=amd64
CONTAINERD_CRI_SOCKET=/run/containerd/containerd.sock

# Kubernetes Configuration
APISERVER_PORT=6443
K8S_IMAGE_REGISTRY=registry.k8s.io
SYSCTL_CONF_FILE=/etc/sysctl.d/99-kubernetes.conf

# Network Configuration
APPLY_IPTABLES_RULES=false
ALLOW_ICMP=false

# Provider Configuration
PACKER_BUILDER_TYPE=nutanix

# System Preparation
RUN_SYSPREP=true

# Images Configuration
IMAGES_LOCAL_BUNDLE_DIR="${IMAGES_LOCAL_BUNDLE_DIR:-/opt/container-images}"
IMAGES_CACHE="${IMAGES_CACHE:-/opt/container-images}"
MINDTHEGAP_BINARY="${MINDTHEGAP_BINARY:-/usr/local/bin/mindthegap}"
CONTAINERD_SUPPLEMENTARY_IMAGES="${CONTAINERD_SUPPLEMENTARY_IMAGES:-ghcr.io/mesosphere/toml-merge:v0.2.0 ghcr.io/mesosphere/dynamic-credential-provider:v0.2.0 ghcr.io/mesosphere/dynamic-credential-provider:v0.5.3}"
CONTROL_PLANE_IMAGES="${CONTROL_PLANE_IMAGES:-}"
EXTRA_IMAGES="${EXTRA_IMAGES:-}"
AWS_IMAGES="${AWS_IMAGES:-}"
K8S_IMAGE_REGISTRY_FOR_COREDNS="${K8S_IMAGE_REGISTRY_FOR_COREDNS:-registry.k8s.io}"

# Configuration variables (can be overridden via environment)
OFFLINE_MODE_ENABLED="${OFFLINE_MODE_ENABLED:-false}"
KUBERNETES_DEB_GPG_KEY_URL="${KUBERNETES_DEB_GPG_KEY_URL:-}"
KUBERNETES_DEB_REPOSITORY_URL="${KUBERNETES_DEB_REPOSITORY_URL:-}"
KUBERNETES_DEB_RELEASE_NAME="${KUBERNETES_DEB_RELEASE_NAME:-/}"
KUBERNETES_DEB_VERSION="${KUBERNETES_DEB_VERSION:-}"
CRITOOLS_DEB="${CRITOOLS_DEB:-}"
CONTAINERD_BASE_URL="${CONTAINERD_BASE_URL:-https://github.com/containerd/containerd/releases}"
CONTAINERD_TAR_FILE="${CONTAINERD_TAR_FILE:-}"
CONTAINERD_REMOTE_BUNDLE_PATH="${CONTAINERD_REMOTE_BUNDLE_PATH:-/opt/containerd}"
APISERVER_PORT="${APISERVER_PORT:-6443}"
PACKER_BUILDER_TYPE="${PACKER_BUILDER_TYPE:-}"
CONTAINERD_CRI_SOCKET="${CONTAINERD_CRI_SOCKET:-/run/containerd/containerd.sock}"
K8S_IMAGE_REGISTRY="${K8S_IMAGE_REGISTRY:-registry.k8s.io}"
SYSCTL_CONF_FILE="${SYSCTL_CONF_FILE:-/etc/sysctl.d/99-kubernetes.conf}"
APPLY_IPTABLES_RULES="${APPLY_IPTABLES_RULES:-false}"
ALLOW_ICMP="${ALLOW_ICMP:-false}"

# Retry function
retry() {
    local max_attempts=$1
    shift
    local delay=$1
    shift
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        if "$@"; then
            return 0
        fi
        if [ $attempt -lt $max_attempts ]; then
            log_warn "Attempt $attempt failed, retrying in ${delay}s..."
            sleep $delay
        fi
        attempt=$((attempt + 1))
    done
    log_error "Failed after $max_attempts attempts"
    return 1
}

# ============================================================================
# REPO ROLE - Debian/Ubuntu specific tasks
# ============================================================================
configure_repo() {
    log_info "Configuring Debian repository..."
    
    if [ "$OFFLINE_MODE_ENABLED" = "true" ]; then
        log_info "Offline mode enabled, skipping repository configuration"
        return 0
    fi

    if [ -z "$KUBERNETES_DEB_GPG_KEY_URL" ] || [ -z "$KUBERNETES_DEB_REPOSITORY_URL" ]; then
        log_warn "Kubernetes repository URLs not set, skipping repository configuration"
        return 0
    fi

    retry 3 3 apt-get update
    retry 3 3 curl -fsSL "$KUBERNETES_DEB_GPG_KEY_URL" | gpg --dearmor -o /usr/share/keyrings/kubernetes-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] $KUBERNETES_DEB_REPOSITORY_URL $KUBERNETES_DEB_RELEASE_NAME" | tee /etc/apt/sources.list.d/kubernetes.list
    retry 3 3 apt-get update
}

# ============================================================================
# CONTAINERD ROLE - Debian/Ubuntu specific and common tasks
# ============================================================================
configure_containerd() {
    log_info "Configuring containerd..."

    # Create containerd systemd drop-in directory
    mkdir -p /etc/systemd/system/containerd.service.d

    # Copy containerd max files config
    cp /opt/nkp/nib/etc/systemd/system/containerd.service.d/max-files.conf /etc/systemd/system/containerd.service.d/max-files.conf
    chmod 0644 /etc/systemd/system/containerd.service.d/max-files.conf

    # Install libseccomp2
    retry 5 10 apt-get install -y libseccomp2

    # Download and install containerd if tar file is specified
    curl -fsSLO "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-static-${CONTAINERD_VERSION}-linux-${CONTAINERD_TARGET_ARCH}.tar.gz"
    curl -fsSLO "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-static-${CONTAINERD_VERSION}-linux-${CONTAINERD_TARGET_ARCH}.tar.gz.sha256sum"
    sha256sum --check "containerd-static-${CONTAINERD_VERSION}-linux-${CONTAINERD_TARGET_ARCH}.tar.gz.sha256sum"
    tar Cxzvf /usr/local "containerd-static-${CONTAINERD_VERSION}-linux-${CONTAINERD_TARGET_ARCH}.tar.gz"

    # Download and set up containerd systemd service
    mkdir -p /usr/lib/systemd/system
    curl -fsSL "https://raw.githubusercontent.com/containerd/containerd/v${CONTAINERD_VERSION}/containerd.service" | sed "s:/usr/local/bin:/usr/bin:g" > /usr/lib/systemd/system/containerd.service
}

# ============================================================================
# PACKAGES ROLE - Debian/Ubuntu specific tasks
# ============================================================================
install_packages() {
    log_info "Installing packages..."

    # Install apt-transport-https
    retry 5 10 apt-get install -y apt-transport-https

    # Install common packages
    retry 5 10 apt-get install -y \
        chrony \
        nfs-common \
        python3-cryptography \
        python3-pip

    # Remove version hold for kubelet and kubectl
    apt-mark unhold kubelet kubectl 2>/dev/null || true

    # Install kubelet and kubectl if version is specified
    if [ -n "$KUBERNETES_DEB_VERSION" ]; then
        log_info "Installing kubelet and kubectl version $KUBERNETES_DEB_VERSION"
        retry 5 10 apt-get install -y --force-yes kubelet="$KUBERNETES_DEB_VERSION" kubectl="$KUBERNETES_DEB_VERSION"

        # Add version hold
        apt-mark hold kubelet kubectl
    fi
}

# ============================================================================
# KUBEADM ROLE - Debian/Ubuntu specific tasks
# ============================================================================
install_kubeadm() {
    log_info "Installing kubeadm..."

    if [ -z "$KUBERNETES_DEB_VERSION" ]; then
        log_warn "Kubernetes version not specified, skipping kubeadm installation"
        return 0
    fi

    # Remove version hold
    apt-mark unhold kubeadm cri-tools 2>/dev/null || true

    # Install cri-tools if version is specified
    if [ -n "$CRITOOLS_DEB" ]; then
        log_info "Installing cri-tools version $CRITOOLS_DEB"
        retry 3 3 apt-get install -y --force-yes cri-tools="$CRITOOLS_DEB"
        apt-mark hold cri-tools
    fi

    # Install kubeadm
    log_info "Installing kubeadm version $KUBERNETES_DEB_VERSION"
    retry 3 3 apt-get install -y --force-yes kubeadm="$KUBERNETES_DEB_VERSION"
    apt-mark hold kubeadm

    # Disable swap
    if swapon -s | grep -q .; then
        log_info "Disabling swap..."
        swapoff -a
    fi
}

# ============================================================================
# CONFIG ROLE - Common tasks
# ============================================================================
configure_system() {
    log_info "Configuring system..."

    # Create kubelet systemd directory
    mkdir -p /etc/systemd/system/kubelet.service.d

    # Copy kubelet drop-in (replace variable)
    sed "s|{{CONTAINERD_CRI_SOCKET}}|$CONTAINERD_CRI_SOCKET|g" /opt/nkp/nib/etc/systemd/system/kubelet.service.d/0-containerd.conf.template > /etc/systemd/system/kubelet.service.d/0-containerd.conf

    # Copy crictl config (replace variable)
    mkdir -p /etc
    sed "s|{{CONTAINERD_CRI_SOCKET}}|$CONTAINERD_CRI_SOCKET|g" /opt/nkp/nib/etc/crictl.yaml.template > /etc/crictl.yaml

    # Create containerd directories
    mkdir -p /etc/containerd/conf.d

    # Set kernel parameters
    log_info "Setting kernel parameters..."
    mkdir -p "$(dirname "$SYSCTL_CONF_FILE")"
    echo "fs.inotify.max_user_instances = 8192" >> "$SYSCTL_CONF_FILE"
    echo "fs.inotify.max_user_watches = 524288" >> "$SYSCTL_CONF_FILE"
    sysctl -p "$SYSCTL_CONF_FILE" 2>/dev/null || sysctl --system
}

# ============================================================================
# NETWORKING ROLE - Common tasks
# ============================================================================
configure_networking() {
    log_info "Configuring networking..."

    # Load br_netfilter module
    modprobe br_netfilter || log_warn "Failed to load br_netfilter module"
    cp /opt/nkp/nib/etc/modules-load.d/konvoy-br_netfilter.conf /etc/modules-load.d/konvoy-br_netfilter.conf

    # Configure sysctl for networking
    cp /opt/nkp/nib/etc/sysctl.d/bridge-nf-call.conf /etc/sysctl.d/bridge-nf-call.conf
    cp /opt/nkp/nib/etc/sysctl.d/ipv4-ip_forward.conf /etc/sysctl.d/ipv4-ip_forward.conf

    if [ -f /proc/sys/net/ipv6/conf/all/forwarding ]; then
        cp /opt/nkp/nib/etc/sysctl.d/ipv6-forwarding.conf /etc/sysctl.d/ipv6-forwarding.conf
    fi

    # Apply sysctl settings
    sysctl --system

    # Configure NetworkManager
    mkdir -p /etc/NetworkManager/conf.d
    cp /opt/nkp/nib/etc/NetworkManager/conf.d/calico.conf /etc/NetworkManager/conf.d/calico.conf

    # Configure iptables rules if enabled
    if [ "$APPLY_IPTABLES_RULES" = "true" ]; then
        log_info "Configuring iptables rules..."
        # Note: iptables rules would be added here
        # This is simplified - full implementation would add all the rules
    fi

    # Copy host.conf if it exists in role files
    if [ -f /ansible/roles/ubuntu_only/files/host.conf ]; then
        cp /ansible/roles/ubuntu_only/files/host.conf /etc/host.conf
    fi
}

# ============================================================================
# PROVIDERS ROLE - Simplified provider tasks
# ============================================================================
configure_providers() {
    log_info "Configuring cloud providers..."

    if [ -z "$PACKER_BUILDER_TYPE" ]; then
        log_info "No packer builder type specified, skipping provider configuration"
        return 0
    fi

    # Create cloud-init directories
    mkdir -p /etc/systemd/system/cloud-final.service.d
    mkdir -p /etc/systemd/system/cloud-config.service.d

    # Copy cloud-init config files if they exist
    if [ -f /ansible/roles/ubuntu_only/files/etc/cloud/cloud.cfg.d/05_logging.cfg ]; then
        mkdir -p /etc/cloud/cloud.cfg.d
        cp /ansible/roles/ubuntu_only/files/etc/cloud/cloud.cfg.d/05_logging.cfg /etc/cloud/cloud.cfg.d/05_logging.cfg
        chmod 0644 /etc/cloud/cloud.cfg.d/05_logging.cfg
    fi

    # Nutanix specific configuration
    if echo "$PACKER_BUILDER_TYPE" | grep -q "nutanix"; then
        log_info "Configuring for Nutanix..."
        cp /opt/nkp/nib/etc/modules-load.d/kubernetes.conf /etc/modules-load.d/kubernetes.conf
    fi
}

# ============================================================================
# Containerd management functions
# ============================================================================
start_containerd_background() {
    log_info "Starting containerd in background..."
    
    # Create necessary directories
    mkdir -p /run/containerd
    mkdir -p /var/lib/containerd
    
    # Start containerd in background
    containerd > /var/log/containerd.log 2>&1 &
    CONTAINERD_PID=$!
    
    # Wait for containerd to be ready (check socket)
    log_info "Waiting for containerd to be ready..."
    local max_wait=30
    local wait_count=0
    while [ $wait_count -lt $max_wait ]; do
        if [ -S "$CONTAINERD_CRI_SOCKET" ] && ctr --address "$CONTAINERD_CRI_SOCKET" version >/dev/null 2>&1; then
            log_info "Containerd is ready"
            break
        fi
        sleep 1
        wait_count=$((wait_count + 1))
    done
    
    if [ $wait_count -ge $max_wait ]; then
        log_error "Containerd failed to start within ${max_wait} seconds"
        if [ -n "$CONTAINERD_PID" ]; then
            kill "$CONTAINERD_PID" 2>/dev/null || true
        fi
        return 1
    fi
    
    # Set trap to ensure containerd is killed on exit
    #trap 'if [ -n "$CONTAINERD_PID" ] && kill -0 "$CONTAINERD_PID" 2>/dev/null; then log_info "Stopping containerd..."; kill "$CONTAINERD_PID" 2>/dev/null || true; wait "$CONTAINERD_PID" 2>/dev/null || true; fi' EXIT INT TERM
    
    return 0
}

stop_containerd_background() {
    if [ -n "$CONTAINERD_PID" ] && kill -0 "$CONTAINERD_PID" 2>/dev/null; then
        log_info "Stopping containerd..."
        # Remove trap first to avoid double cleanup
        trap - EXIT INT TERM
        kill "$CONTAINERD_PID" 2>/dev/null || true
        # Wait for containerd to stop (with timeout)
        local stop_wait=0
        while [ $stop_wait -lt 10 ] && kill -0 "$CONTAINERD_PID" 2>/dev/null; do
            sleep 1
            stop_wait=$((stop_wait + 1))
        done
        # Force kill if still running
        if kill -0 "$CONTAINERD_PID" 2>/dev/null; then
            log_warn "Containerd did not stop gracefully, force killing..."
            kill -9 "$CONTAINERD_PID" 2>/dev/null || true
        fi
        wait "$CONTAINERD_PID" 2>/dev/null || true
        CONTAINERD_PID=""
        log_info "Containerd stopped"
    fi
}

# ============================================================================
# IMAGES ROLE - Image management tasks
# ============================================================================
configure_images() {
    log_info "Configuring container images..."

    # Start containerd in background
    CONTAINERD_PID=""
    if ! start_containerd_background; then
        return 1
    fi
   
    # Load images from bundles if they exist
    if [ -d "$IMAGES_CACHE" ] && [ -n "$(find "$IMAGES_CACHE" -maxdepth 1 -name '*.tar' -o -name '*.tar.gz' 2>/dev/null)" ]; then
        log_info "Loading images from bundles in $IMAGES_CACHE..."
        
        for bundle_file in "$IMAGES_CACHE"/*.tar*; do
            if [ -f "$bundle_file" ]; then
                log_info "Importing image bundle: $bundle_file"
                TMPDIR="${TMPDIR:-/var/tmp}" "$MINDTHEGAP_BINARY" import image-bundle --image-bundle="$bundle_file"                
                # Remove imported bundle
                rm -f "$bundle_file"
            fi
        done
    fi

    # Determine kubernetes images using kubeadm
    if command -v kubeadm >/dev/null 2>&1; then
        log_info "Determining Kubernetes images using kubeadm..."
        
        # Get kubeadm version
        KUBEADM_VERSION=$(kubeadm version -o short 2>/dev/null | tr -d ' ' || echo "")
        
        # Create temporary kubeadm config
        KUBEADM_CONF=$(mktemp)
        cat > "$KUBEADM_CONF" <<EOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
dns:
  imageRepository: ${K8S_IMAGE_REGISTRY_FOR_COREDNS}
imageRepository: ${K8S_IMAGE_REGISTRY}
kubernetesVersion: ${KUBEADM_VERSION:-v${KUBERNETES_VERSION}}
EOF
        
        # Get kubernetes images list
        KUBERNETES_IMAGES=$(kubeadm config images list --config "$KUBEADM_CONF" 2>/dev/null || echo "")
        rm -f "$KUBEADM_CONF"
        
        if [ -z "$KUBERNETES_IMAGES" ]; then
            log_warn "Failed to get kubernetes images from kubeadm, skipping image pulls"
            return 0
        fi
    else
        log_warn "kubeadm not found, skipping image configuration"
        return 0
    fi

    # Get containerd sandbox image
    CONTAINERD_SANDBOX_IMAGE=""
    # if command -v containerd >/dev/null 2>&1; then
    #     CONTAINERD_CONFIG=$(containerd config default 2>/dev/null || echo "")
    #     if [ -n "$CONTAINERD_CONFIG" ]; then
    #         CONTAINERD_SANDBOX_IMAGE=$(echo "$CONTAINERD_CONFIG" | grep 'sandbox_image' | sed 's/.*sandbox_image = "\([^"]*\)".*/\1/' | head -1)
    #     fi
    # fi

    # Build pull images array
    PULL_IMAGES_ARRAY=()
    
    # Add kubernetes images (split by newline)
    while IFS= read -r line; do
        [ -n "$line" ] && PULL_IMAGES_ARRAY+=("$line")
    done <<< "$KUBERNETES_IMAGES"
    
    # Add containerd sandbox image if found
    if [ -n "$CONTAINERD_SANDBOX_IMAGE" ]; then
        PULL_IMAGES_ARRAY+=("$CONTAINERD_SANDBOX_IMAGE")
    fi
    
    # Add supplementary images (space or newline separated)
    if [ -n "$CONTAINERD_SUPPLEMENTARY_IMAGES" ]; then
        for img in $CONTAINERD_SUPPLEMENTARY_IMAGES; do
            [ -n "$img" ] && PULL_IMAGES_ARRAY+=("$img")
        done
    fi
    
    # Add control plane images (space or newline separated)
    if [ -n "$CONTROL_PLANE_IMAGES" ]; then
        for img in $CONTROL_PLANE_IMAGES; do
            [ -n "$img" ] && PULL_IMAGES_ARRAY+=("$img")
        done
    fi
    
    # Add extra images (space or newline separated)
    if [ -n "$EXTRA_IMAGES" ]; then
        for img in $EXTRA_IMAGES; do
            [ -n "$img" ] && PULL_IMAGES_ARRAY+=("$img")
        done
    fi
    
    # Add AWS images if packer builder type is amazon
    if echo "$PACKER_BUILDER_TYPE" | grep -q "^amazon"; then
        if [ -n "$AWS_IMAGES" ]; then
            for img in $AWS_IMAGES; do
                [ -n "$img" ] && PULL_IMAGES_ARRAY+=("$img")
            done
        fi
    fi

    # Pull images that are not already present
    log_info "Checking and pulling required images..."
    for image_name in "${PULL_IMAGES_ARRAY[@]}"; do
        [ -z "$image_name" ] && continue
        
        log_info "Checking image: $image_name"
        
        # Check if image exists and is complete
        if ctr --address "$CONTAINERD_CRI_SOCKET" --namespace k8s.io images check name=="$image_name" >/dev/null 2>&1; then
            CHECK_OUTPUT=$(ctr --address "$CONTAINERD_CRI_SOCKET" --namespace k8s.io images check name=="$image_name" 2>&1)
            if echo "$CHECK_OUTPUT" | grep -q "^${image_name}$"; then
                log_info "Image $image_name already exists and is complete, skipping"
                continue
            fi
        fi
        
        log_info "Pulling image: $image_name"
        if crictl pull "$image_name"; then
            log_info "Successfully pulled $image_name"
        else
            log_warn "Failed to pull $image_name"
            continue
        fi
        
        # Retag coredns image if needed
        if echo "$image_name" | grep -q "${K8S_IMAGE_REGISTRY_FOR_COREDNS}/coredns/coredns"; then
            COREDNS_TAG=$(echo "$image_name" | sed 's/.*://')
            RETAG_IMAGE="k8s.gcr.io/coredns:${COREDNS_TAG}"
            log_info "Retagging coredns image: $image_name -> $RETAG_IMAGE"
            ctr --address "$CONTAINERD_CRI_SOCKET" --namespace k8s.io image tag --force "$image_name" "$RETAG_IMAGE" || log_warn "Failed to retag coredns image"
        fi
    done
    
    log_info "Image configuration completed"
    
    # Stop containerd if we started it in background
    #stop_containerd_background
}

# ============================================================================
# SYSPREP ROLE - System preparation tasks
# ============================================================================
sysprep_system() {
    log_info "Running system preparation..."

    # Remove apt package caches
    retry 5 10 apt-get autoclean -y
    retry 5 10 apt-get autoremove -y

    # Remove apt package lists
    rm -rf /var/lib/apt/lists/*
    mkdir -p /var/lib/apt/lists
    chmod 0755 /var/lib/apt/lists

    # Reset network interface IDs
    rm -f /etc/udev/rules.d/70-persistent-net.rules

    # Truncate machine-id
    rm -f /etc/machine-id
    touch /etc/machine-id
    chmod 0644 /etc/machine-id

    # Truncate hostname file
    # Set hostname
    echo "localhost.local" > /etc/hostname

    # Reset hosts file
    if [ -f /ansible/roles/ubuntu_only/files/etc/hosts ]; then
        cp /ansible/roles/ubuntu_only/files/etc/hosts /etc/hosts
        chmod 0644 /etc/hosts
    fi

    # Truncate audit logs
    rm -f /var/log/wtmp /var/log/lastlog
    touch /var/log/wtmp /var/log/lastlog
    chmod 0664 /var/log/wtmp
    chmod 0664 /var/log/lastlog

    # Remove cloud-init lib dir and logs
    rm -rf /var/lib/cloud
    rm -f /var/log/cloud-init.log /var/log/cloud-init-output.log
    rm -rf /var/run/cloud-init

    # Reset temp space (shallow cleanup)
    find /tmp -mindepth 1 -maxdepth 1 ! -name '.ansible' -exec rm -rf {} + 2>/dev/null || true
    find /var/tmp -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true

    # Remove SSH host keys
    find /etc/ssh -name 'ssh_host_*' -type f -delete 2>/dev/null || true

    # Remove SSH authorized keys
    rm -f /root/.ssh/authorized_keys

    # Truncate log files
    find /var/log -type f -iname '*.log' -exec truncate -s 0 {} + 2>/dev/null || true
    find /var/log -type f -name '*.gz' -delete 2>/dev/null || true

    # Truncate shell history
    rm -f /root/.bash_history

    # Disable password authentication in SSH
    if [ -f /etc/ssh/sshd_config ]; then
        sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    fi
}

# ============================================================================
# Main execution
# ============================================================================
main() {
    log_info "Starting Ubuntu configuration script..."
    log_info "Offline mode: $OFFLINE_MODE_ENABLED"
    log_info "Packer builder type: ${PACKER_BUILDER_TYPE:-not set}"

    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root"
        exit 1
    fi

    # Update package lists
    apt-get update

    # Execute configuration steps
    configure_repo
    configure_containerd
    install_packages
    install_kubeadm
    configure_system
    configure_networking
    configure_providers
    configure_images

    # Sysprep is typically run at the end
    if [ "${RUN_SYSPREP:-false}" = "true" ]; then
        sysprep_system
    fi

    log_info "Configuration completed successfully!"
}

# Run main function
main "$@"

