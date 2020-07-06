#!/usr/bin/env bash
debug="false"
wait="true"
time2wait=3

CLOUD_IMG_FOLDER="/home/xavi/Documents/isos/cloud-imgs"
POOL_FOLDER="/var/lib/libvirt/images"
CLOUD_IMG_NAME="focal-server-cloudimg-amd64.img"
KVM_PARAM_OSVARIANT="ubuntu20.04"
KVM_PARAM_MEMORY=2048
KVM_PARAM_VCPU=2
VM_DISK_SIZE="10G"

VM_NAME="docker"
VM_HOSTNAME=$VM_NAME
VM_USERNAME="operador"

CLOUD_CONFIG_FILE="/tmp/$VM_NAME-cloudinit.config"
# -----------------------------------------
echo "Enter the password for the user $VM_USERNAME on the VM"
VM_ENCRYPTED_PASSWORD=$(/usr/bin/python3 -c 'import crypt,getpass; print(crypt.crypt(getpass.getpass(), crypt.mksalt(crypt.METHOD_SHA512)))')
/bin/cat >$CLOUD_CONFIG_FILE <<ENDOFCONFIG
#cloud-config
users:
  - default
  - name: $VM_USERNAME
    # passwd: The hash -not the password itself- of the password you want to use for this user.
    passwd: $VM_ENCRYPTED_PASSWORD
    chpasswd: { expire: false }
    # lock_passwd: Defaults to true. Lock the password to disable password login.
    lock_passwd: false
    # sudo: Defaults to none. Accepts a sudo rule string, a list of sudo rule
    #       strings or False to explicitly deny sudo usage.
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash

# Enable login with password
ssh_pwauth: True

# Install additional packages on first boot
# if packages are specified, apt_update will be set to true
packages:
  - qemu-guest-agent
  - apt-transport-https
  - ca-certificates
  - curl
  - gnupg-agent
  - software-properties-common

hostname: $VM_HOSTNAME

# Ref: https://gist.github.com/syntaqx/9dd3ff11fb3d48b032c84f3e31af9163
runcmd:
  - systemctl enable qemu-guest-agent
  - systemctl start qemu-guest-agent
  - curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
  - add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
  - apt-get update -y
  - apt-get install -y docker-ce docker-ce-cli containerd.io
  - systemctl start docker
  - systemctl enable docker

final_message: "The system is finally up, after $UPTIME seconds"
ENDOFCONFIG
# -----------------------------------------

# See the config file
if [ $debug = "true" ]; then xdg-open $CLOUD_CONFIG_FILE; fi
# Get info on original image
if [ $debug = "true" ]; then qemu-img info "$CLOUD_IMG_FOLDER/$CLOUD_IMG_NAME"; fi

# Copy cloud image from iso folder to default pool location
echo "Copying image from $CLOUD_IMG_FOLDER/$CLOUD_IMG_NAME to $POOL_FOLDER/$VM_NAME.img ..."
sudo qemu-img convert -p "$CLOUD_IMG_FOLDER/$CLOUD_IMG_NAME" -O qcow2 "$POOL_FOLDER/$VM_NAME.img" 

# Expand system's disk
echo "Resizing image $POOL_FOLDER/$VM_NAME.img ..."
sudo qemu-img resize -f raw "$POOL_FOLDER/$VM_NAME.img" $VM_DISK_SIZE

# Create seed.img with cloud-init config 
# Check if cloud-image-utils is installed (only for Debian/Ubuntu and maybe other DEB-based distros)
is_installed=$(apt -qq list cloud-image-utils)
if [ $debug = "true" ]; then echo $is_installed; fi
if [[ $is_installed =~ "installed" ]]; then
    sudo cloud-localds "$POOL_FOLDER/$VM_NAME.cloudconfig.img" $CLOUD_CONFIG_FILE
else
    echo "[ERROR] cloud-image-utils is not installed."
fi

# Boot with seed.img

sudo virt-install --name $VM_NAME --virt-type kvm --hvm --os-variant=$KVM_PARAM_OSVARIANT --memory $KVM_PARAM_MEMORY --vcpus $KVM_PARAM_VCPU --network network=default,model=virtio --graphics spice --disk "$POOL_FOLDER/$VM_NAME.img",device=disk,bus=virtio --disk "$POOL_FOLDER/$VM_NAME.cloudconfig.img",device=cdrom --noautoconsole --import

if [ $wait = "true" ]; then
  # Waiting until cloud-init finishes
  virsh qemu-agent-command $VM_NAME --cmd '{"execute": "guest-file-open", "arguments": {"path":"/var/lib/cloud/instance/boot-finished"}}' 1>/dev/null 2>/dev/null
  while [ $? -ne 0 ]; do
    sleep $time2wait
    echo "... waiting for cloud-init $time2wait more seconds ..."
    virsh qemu-agent-command $VM_NAME --cmd '{"execute": "guest-file-open", "arguments": {"path":"/var/lib/cloud/instance/boot-finished"}}' 1>/dev/null 2>/dev/null
  done
  echo "cloud-init configuration process finished."

  echo "Ejecting $POOL_FOLDER/$VM_NAME.cloudconfig.img from $VM_NAME ..."
  virsh change-media --path "$POOL_FOLDER/$VM_NAME.cloudconfig.img" $VM_NAME --eject

  virsh domifaddr $VM_NAME
fi 
