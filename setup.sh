#!/bin/bash

echo
echo "=== Requesting configuration data ==="
echo

read -p "Timezone (e.g. Europe/London): " TZONE
read -p "Email for sysadmin: " EMAIL
read -p "Port for SSH: " SSHPORT
echo

read -p "Login username: " LOGINUSERNAME
while true; do
  read -s -p "Login password: " LOGINPASSWORD
  echo
  read -s -p "Confirm login password: " LOGINPASSWORD2
  echo
  [ "$LOGINPASSWORD" = "$LOGINPASSWORD2" ] && break
  echo "Please try again"
done
echo

read -p "Hostname for VPN (e.g. ikev2.example.com): " VPNHOST

read -p "VPN username: " VPNUSERNAME
while true; do
read -s -p "VPN password: " VPNPASSWORD
echo
read -s -p "Confirm VPN password: " VPNPASSWORD2
echo
[ "$VPNPASSWORD" = "$VPNPASSWORD2" ] && break
echo "Please try again"
done

VPNKEYFILE="vpn_private.key"
VPNCRTFILE="vpn_public.crt"

echo "Delete this message (Ctrl-K), paste in the StartSSL PRIVATE KEY, then save and exit (Ctrl-O, Ctrl-X)" > "/tmp/${VPNKEYFILE}"
vim "/tmp/${VPNKEYFILE}"

echo "Delete this message (Ctrl-K), paste in the StartSSL CERTIFICATE, then save and exit (Ctrl-O, Ctrl-X)" > "/tmp/${VPNCRTFILE}"
vim "/tmp/${VPNCRTFILE}"

VPNIPPOOL="10.31.2.0/24"
ELASTIC_IP="118.193.207.78"



echo
echo "=== Updating and installing software ==="
echo

export DEBIAN_FRONTEND=noninteractive
aptitude update && aptitude safe-upgrade -y

debconf-set-selections <<< "postfix postfix/mailname string ${VPNHOST}"
debconf-set-selections <<< "postfix postfix/main_mailer_type string 'Internet Site'"

aptitude install -y strongswan strongswan-plugin-eap-mschapv2 moreutils iptables-persistent postfix mailutils unattended-upgrades

IP=$(ifdata -pa eth0)



echo
echo "=== Configuring firewall ==="
echo

# firewall
# https://www.strongswan.org/docs/LinuxKongress2009-strongswan.pdf
# https://wiki.strongswan.org/projects/strongswan/wiki/ForwardingAndSplitTunneling
# https://www.zeitgeist.se/2013/11/26/mtu-woes-in-ipsec-tunnels-how-to-fix/

iptables -A FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -s 10.31.0.0/24  -j ACCEPT
iptables -A FORWARD -s 10.31.1.0/24  -j ACCEPT
iptables -A FORWARD -s 10.31.2.0/24  -j ACCEPT
iptables -A INPUT -i eth0 -p esp -j ACCEPT
iptables -A INPUT -i eth0 -p udp --dport 500 -j ACCEPT
iptables -A INPUT -i eth0 -p tcp --dport 500 -j ACCEPT
iptables -A INPUT -i eth0 -p udp --dport 4500 -j ACCEPT
iptables -A INPUT -i eth0 -p udp --dport 1701 -j ACCEPT
iptables -A INPUT -i eth0 -p tcp --dport 1723 -j ACCEPT
iptables -A FORWARD -j REJECT

iptables -t nat -A POSTROUTING -s 10.31.0.0/24 -o eth0 -j SNAT --to-source $ELASTIC_IP
iptables -t nat -A POSTROUTING -s 10.31.1.0/24 -o eth0 -j SNAT --to-source $ELASTIC_IP
iptables -t nat -A POSTROUTING -s 10.31.2.0/24 -o eth0 -j SNAT --to-source $ELASTIC_IP

iptables -L
/etc/init.d/iptables-persistent save



echo
echo "=== Configuring RSA certificates ==="
echo

VPNKEYPATH="/etc/ipsec.d/private/${VPNKEYFILE}"
mv "/tmp/${VPNKEYFILE}" "${VPNKEYPATH}"
chmod 600 "${VPNKEYPATH}"

VPNCRTPATH="/etc/ipsec.d/certs/${VPNCRTFILE}"
mv "/tmp/${VPNCRTFILE}" "${VPNCRTPATH}"
chmod 640 "${VPNCRTPATH}"

INTCRTPATH="/etc/ipsec.d/cacerts/sub.class1.server.ca.pem"
curl "https://www.startssl.com/certs/sub.class1.server.ca.pem" > "${INTCRTPATH}"
chmod 640 "${INTCRTPATH}"



echo
echo "=== Configuring VPN ==="
echo

# ip_forward is for VPN
# ip_no_pmtu_disc is for UDP fragmentation
# others are for security

echo '
net.ipv4.ip_forward = 1
net.ipv4.ip_no_pmtu_disc = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
' >> /etc/sysctl.conf

sysctl -p


echo "config setup
  strictcrlpolicy=yes
  uniqueids=no

conn roadwarrior
  auto=add
  compress=no
  type=tunnel
  keyexchange=ikev2
  fragmentation=yes
  forceencaps=yes
  ike=aes256-sha1-modp1024,3des-sha1-modp1024!
  esp=aes256-sha1,3des-sha1!
  dpdaction=clear
  dpddelay=300s
  rekey=no
  left=%any
  leftid=@${VPNHOST}
  leftcert=${VPNCRTFILE}
  leftsendcert=always
  leftsubnet=0.0.0.0/0
  right=%any
  rightid=%any
  rightauth=eap-mschapv2
  eap_identity=%any
  rightdns=8.8.8.8,8.8.4.4
  rightsourceip=${VPNIPPOOL}
  rightsendcert=never
" > /etc/ipsec.conf

echo "${VPNHOST} : RSA \"${VPNKEYFILE}\"
${VPNUSERNAME} %any : EAP \""${VPNPASSWORD}"\"
" > /etc/ipsec.secrets

ipsec restart



echo
echo "=== User ==="
echo

# user + SSH

adduser --disabled-password --gecos "" $LOGINUSERNAME
echo "${LOGINUSERNAME}:${LOGINPASSWORD}" | chpasswd
adduser ${LOGINUSERNAME} sudo

sed -r \
-e "s/^Port 22$/Port ${SSHPORT}/" \
-e 's/^LoginGraceTime 120$/LoginGraceTime 30/' \
-e 's/^PermitRootLogin yes$/PermitRootLogin no/' \
-e 's/^X11Forwarding yes$/X11Forwarding no/' \
-e 's/^UsePAM yes$/UsePAM no/' \
-i.original /etc/ssh/sshd_config

echo "
MaxStartups 1
MaxAuthTries 2
UseDNS no" >> /etc/ssh/sshd_config

service ssh restart


echo
echo "=== Timezone, mail, unattended upgrades ==="
echo

echo "${TZONE}" > /etc/timezone

locale-gen en_GB.UTF-8
/usr/sbin/update-locale LANG=en_GB.UTF-8
dpkg-reconfigure -f noninteractive tzdata


sed -r \
-e "s/^myhostname =.*$/myhostname = ${VPNHOST}/" \
-e 's/^inet_interfaces =.*$/inet_interfaces = loopback-only/' \
-i.original /etc/postfix/main.cf

echo "root: ${EMAIL}
${LOGINUSERNAME}: ${EMAIL}
" >> /etc/aliases

newaliases

service postfix restart


sed -r \
-e 's|^//\s*"\$\{distro_id\}:\$\{distro_codename\}-updates";$|        "${distro_id}:${distro_codename}-updates";|' \
-e 's|^//Unattended-Upgrade::MinimalSteps "true";$|Unattended-Upgrade::MinimalSteps "true";|' \
-e 's|^//Unattended-Upgrade::Mail "root";$|Unattended-Upgrade::Mail "root";|' \
-e 's|^//Unattended-Upgrade::Automatic-Reboot "false";$|Unattended-Upgrade::Automatic-Reboot "true";|' \
-i /etc/apt/apt.conf.d/50unattended-upgrades

echo 'APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
' > /etc/apt/apt.conf.d/10periodic

service unattended-upgrades restart


# necessary for IKEv2?
# Windows: https://support.microsoft.com/en-us/kb/926179
# HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\PolicyAgent += AssumeUDPEncapsulationContextOnSendRule, DWORD = 2

