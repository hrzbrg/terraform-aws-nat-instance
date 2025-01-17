#!/bin/sh

yum install iptables-services -y

if test -f "/etc/nat.conf"; then
    echo "Found nat configuration at /etc/nat.conf"
    . /etc/nat.conf
else
    echo "No nat configuration at /etc/nat.conf"
fi

if test -n "$eni_id"; then
    echo "Found eni_id configuration, attaching $eni_id..."

    aws_region="$(/opt/aws/bin/ec2-metadata -z | cut -f2 -d' ' | sed 's/.$//')"
    instance_id="$(/opt/aws/bin/ec2-metadata -i | cut -f2 -d' ')"

    eth0_mac="$(cat /sys/class/net/eth0/address)"

    token="$(curl -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 300' http://169.254.169.254/latest/api/token)"
    eth0_eni_id="$(curl -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/network/interfaces/macs/$eth0_mac/interface-id)"

    aws ec2 modify-network-interface-attribute \
        --region "$aws_region" \
        --network-interface-id "$eth0_eni_id" \
        --no-source-dest-check

    aws ec2 attach-network-interface \
        --region "$aws_region" \
        --instance-id "$instance_id" \
        --device-index 1 \
        --network-interface-id "$eni_id"

    while ! ip link show dev eth1; do
        echo "Waiting for ENI to come up..."
        sleep 1
    done

    nat_interface="eth0"
elif test -n "$interface"; then
    echo "Found interface configuration, using $interface"
    nat_interface=$interface
else
    nat_interface=$(ip route | grep default | cut -d ' ' -f 5)
    echo "No eni_id or interface configuration found, using default interface $nat_interface"
fi

echo "Enabling ip_forward..."
sysctl -q -w net.ipv4.ip_forward=1
sysctl -q -w net.ipv4.ip_local_port_range="1024 65535"

echo "Disabling reverse path protection..."
for i in $(find /proc/sys/net/ipv4/conf/ -name rp_filter) ; do
  echo 0 > $i;
done

echo "Flushing NAT table..."
iptables -t nat -F

echo "Adding NAT rule..."
iptables -t nat -A POSTROUTING -o "$nat_interface" -j MASQUERADE -m comment --comment "NAT routing rule installed"

service iptables save

echo "Installing SSM Agent"
yum install -y https://s3.eu-central-1.amazonaws.com/amazon-ssm-eu-central-1/latest/linux_arm64/amazon-ssm-agent.rpm
systemctl enable amazon-ssm-agent
systemctl start amazon-ssm-agent

echo "Done!"
