
# ------------------------------
# Azure WP + NFS referencia telepítés
# Szerver: Ubuntu 24.04 LTS  |  Kliens: Debian 12 (GUI)
# Domain / TLS: szagi.biztositasonline.hu (Let's Encrypt, automatikus)
# Hálózat: belső Subnet, szigorú NSG + UFW
# ------------------------------

param(
  [string]$SubscriptionId = "643b6c9a-f082-4e5d-a8a5-e2dde8f0ec61",
  [string]$ResourceGroupName = "rg-wp-nfs-demo",
  [string]$Location = "westeurope",

  # Hálózat
  [string]$VNetName = "vnet-wp",
  [string]$SubnetName = "subnet-wp",
  [string]$VNetAddressPrefix = "10.20.0.0/16",
  [string]$SubnetPrefix = "10.20.1.0/24",

  # VM-ek
  [string]$ServerVmName = "srv-ubuntu2404",
  [string]$ClientVmName = "cli-debian12",
  [string]$ServerSize = "Standard_B2s",
  [string]$ClientSize = "Standard_B2ms",

  # DNS/LE
  [string]$DomainName = "szagi.biztositasonline.hu",

  # Auth
  [string]$SshPublicKeyPath = "$HOME/.ssh/id_rsa.pub",

  # WP DB jelszó (ha üres, generál)
  [string]$WpDbPassword = ""
)

if ($SubscriptionId) { Set-AzContext -SubscriptionId $SubscriptionId }

if (-not (Test-Path $SshPublicKeyPath)) { throw "SSH public key not found: $SshPublicKeyPath" }
$SshPublicKey = (Get-Content -Raw $SshPublicKeyPath).Trim()

if ([string]::IsNullOrWhiteSpace($WpDbPassword)) {
  $WpDbPassword = ("WP-" + [Guid]::NewGuid().ToString("N").Substring(0,16))
}

# Corvinus ASN (AS25171) publikus tartománya - NSG/UFW whitelist
$CorvinusCidr = "146.110.0.0/16"   # forrás: publikus RIPE/ASN adat

# ---------- Resource Group ----------
$rg = New-AzResourceGroup -Name $ResourceGroupName -Location $Location

# ---------- VNet / Subnet ----------
$vnet = New-AzVirtualNetwork -Name $VNetName -ResourceGroupName $ResourceGroupName -Location $Location -AddressPrefix $VNetAddressPrefix
$vnet | Add-AzVirtualNetworkSubnetConfig -Name $SubnetName -AddressPrefix $SubnetPrefix | Set-AzVirtualNetwork | Out-Null

# ---------- NSG-k ----------
$serverNsg = New-AzNetworkSecurityGroup -Name "nsg-$ServerVmName" -ResourceGroupName $ResourceGroupName -Location $Location
$clientNsg = New-AzNetworkSecurityGroup -Name "nsg-$ClientVmName" -ResourceGroupName $ResourceGroupName -Location $Location

# Szerver: HTTPS csak Corvinus felől
$ruleSrvHttpsCorv = New-AzNetworkSecurityRuleConfig -Name "allow-https-corvinus" -Access Allow -Protocol Tcp -Direction Inbound -Priority 100 `
  -SourceAddressPrefix $CorvinusCidr -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 443
$serverNsg.SecurityRules += $ruleSrvHttpsCorv
$serverNsg | Set-AzNetworkSecurityGroup | Out-Null
$clientNsg | Set-AzNetworkSecurityGroup | Out-Null

# ---------- Publikus IP csak a szervernek ----------
$serverPip = New-AzPublicIpAddress -Name "pip-$ServerVmName" -ResourceGroupName $ResourceGroupName -Location $Location -AllocationMethod Static -Sku Standard

# ---------- NIC-ek ----------
$subnetObj = (Get-AzVirtualNetwork -Name $VNetName -ResourceGroupName $ResourceGroupName).Subnets | Where-Object {$_.Name -eq $SubnetName}
$serverNic = New-AzNetworkInterface -Name "nic-$ServerVmName" -ResourceGroupName $ResourceGroupName -Location $Location `
  -Subnet $subnetObj -NetworkSecurityGroup $serverNsg -PublicIpAddress $serverPip
$clientNic = New-AzNetworkInterface -Name "nic-$ClientVmName" -ResourceGroupName $ResourceGroupName -Location $Location `
  -Subnet $subnetObj -NetworkSecurityGroup $clientNsg

# Privát IP-k (a NIC-ek statikus privát IP-t az allokáció után kapnak)
$serverPrivateIp = ($serverNic.IpConfigurations[0].PrivateIpAddress)
$clientPrivateIp = ($clientNic.IpConfigurations[0].PrivateIpAddress)

# ---------- cloud-init (Server) ----------
$cloudInitServer = @"
#cloud-config
package_update: true
package_upgrade: true
packages:
  - nfs-kernel-server
  - apache2
  - mariadb-server
  - php
  - php-mysql
  - php-curl
  - php-xml
  - php-gd
  - php-intl
  - php-mbstring
  - unzip
  - certbot
  - python3-certbot-apache
  - ufw

users:
  - name: szagi
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    groups: [sudo]
    shell: /bin/bash
    ssh-authorized-keys:
      - __SSH_KEY__

write_files:
  - path: /root/wp-db-init.sql
    permissions: '0600'
    content: |
      CREATE DATABASE wordpress DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
      CREATE USER 'wp_user'@'localhost' IDENTIFIED BY '__WP_PASS__';
      GRANT ALL PRIVILEGES ON wordpress.* TO 'wp_user'@'localhost';
      FLUSH PRIVILEGES;
  - path: /etc/mysql/mariadb.conf.d/60-bind.cnf
    permissions: '0644'
    content: |
      [mysqld]
      bind-address = 127.0.0.1
  - path: /etc/exports
    permissions: '0644'
    content: |
      /files01 __SUBNET__/24(rw,sync,no_subtree_check,fsid=0)
  - path: /etc/apache2/sites-available/wordpress.conf
    permissions: '0644'
    content: |
      <VirtualHost *:80>
        ServerName __DOMAIN__
        RewriteEngine On
        RewriteCond %{HTTPS} off
        RewriteRule ^(.*)$ https://%{HTTP_HOST}%{REQUEST_URI} [L,R=301]
      </VirtualHost>

runcmd:
  # NFS
  - mkdir -p /files01
  - chown -R nobody:nogroup /files01
  - chmod 0777 /files01
  - systemctl enable nfs-server
  - systemctl restart nfs-server
  - exportfs -ra

  # MariaDB + WordPress DB
  - systemctl enable mariadb
  - systemctl start mariadb
  - mysql < /root/wp-db-init.sql

  # WordPress
  - curl -L https://wordpress.org/latest.tar.gz -o /root/wp.tgz
  - tar -xzf /root/wp.tgz -C /var/www
  - chown -R www-data:www-data /var/www/wordpress
  - chmod -R 755 /var/www/wordpress
  - cp /var/www/wordpress/wp-config-sample.php /var/www/wordpress/wp-config.php
  - sed -i "s/database_name_here/wordpress/" /var/www/wordpress/wp-config.php
  - sed -i "s/username_here/wp_user/" /var/www/wordpress/wp-config.php
  - sed -i "s/password_here/__WP_PASS__/" /var/www/wordpress/wp-config.php
  - sed -i "s/localhost/127.0.0.1/" /var/www/wordpress/wp-config.php
  - sed -i "1 a define('FS_METHOD', 'direct');" /var/www/wordpress/wp-config.php

  # Apache
  - a2enmod rewrite ssl
  - a2dissite 000-default || true
  - a2ensite wordpress
  - systemctl restart apache2

  # UFW kezdeti korlátozás (összhangban az NSG-vel)
  - ufw default deny incoming
  - ufw default allow outgoing
  - ufw allow from __CLIENT_IP__ to any port 22 proto tcp
  - ufw allow from __CLIENT_IP__ to any port 2049 proto tcp
  - ufw allow from __CORVINUS__ to any port 443 proto tcp
  - yes | ufw enable
"@

# ---------- cloud-init (Client) ----------
$cloudInitClient = @"
#cloud-config
package_update: true
package_upgrade: true
packages:
  - nfs-common
  - ufw
  - xfce4
  - lightdm

users:
  - name: szagi
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    groups: [sudo]
    shell: /bin/bash
    ssh-authorized-keys:
      - __SSH_KEY__

write_files:
  - path: /etc/fstab
    append: true
    content: |
      __SERVER_IP__:/files01 /serverfiles nfs4 defaults,_netdev 0 0

runcmd:
  - mkdir -p /serverfiles
  - mount -a
  - ufw default deny incoming
  - ufw default allow outgoing
  - yes | ufw enable
"@

# Token csere
$cloudInitServer = $cloudInitServer.Replace("__SSH_KEY__", $SshPublicKey).
  Replace("__WP_PASS__", $WpDbPassword).
  Replace("__SUBNET__", ($SubnetPrefix -replace "/\d+$","")).
  Replace("__DOMAIN__", $DomainName).
  Replace("__CLIENT_IP__", $clientPrivateIp).
  Replace("__CORVINUS__", $CorvinusCidr)

$cloudInitClient = $cloudInitClient.Replace("__SSH_KEY__", $SshPublicKey).
  Replace("__SERVER_IP__", $serverPrivateIp)

# UserData (Base64)
$serverUserData = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($cloudInitServer))
$clientUserData = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($cloudInitClient))

# ---------- VM: Server (Ubuntu 24.04) ----------
$serverVmConfig = New-AzVMConfig -VMName $ServerVmName -VMSize $ServerSize
$serverCred = New-Object System.Management.Automation.PSCredential ("szagi",(ConvertTo-SecureString "DisabledLoginUseSSH" -AsPlainText -Force))
$serverVmConfig = Set-AzVMOperatingSystem -VM $serverVmConfig -Linux -ComputerName $ServerVmName -Credential $serverCred -DisablePasswordAuthentication
$serverVmConfig = Add-AzVMNetworkInterface -VM $serverVmConfig -Id $serverNic.Id
$serverVmConfig = Set-AzVMSourceImage -VM $serverVmConfig -PublisherName "Canonical" -Offer "ubuntu-24_04-lts" -Skus "server" -Version "latest"
$serverVmConfig.UserData = $serverUserData
$null = New-AzVM -ResourceGroupName $ResourceGroupName -Location $Location -VM $serverVmConfig

# ---------- VM: Client (Debian 12, GUI, publikus IP nélkül) ----------
$clientVmConfig = New-AzVMConfig -VMName $ClientVmName -VMSize $ClientSize
$clientCred = New-Object System.Management.Automation.PSCredential ("szagi",(ConvertTo-SecureString "DisabledLoginUseSSH" -AsPlainText -Force))
$clientVmConfig = Set-AzVMOperatingSystem -VM $clientVmConfig -Linux -ComputerName $ClientVmName -Credential $clientCred -DisablePasswordAuthentication
$clientVmConfig = Add-AzVMNetworkInterface -VM $clientVmConfig -Id $clientNic.Id
$clientVmConfig = Set-AzVMSourceImage -VM $clientVmConfig -PublisherName "Debian" -Offer "debian-12" -Skus "12-gen2" -Version "latest"
$clientVmConfig.UserData = $clientUserData
$null = New-AzVM -ResourceGroupName $ResourceGroupName -Location $Location -VM $clientVmConfig

# ---------- NSG finomhangolás: szerverre SSH+NFS csak a kliens privát IP-jéről ----------
$serverNsg = Get-AzNetworkSecurityGroup -Name "nsg-$ServerVmName" -ResourceGroupName $ResourceGroupName
$serverNsg.SecurityRules += New-AzNetworkSecurityRuleConfig -Name "allow-ssh-from-client" -Access Allow -Protocol Tcp -Direction Inbound -Priority 110 `
  -SourceAddressPrefix $clientPrivateIp -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 22
$serverNsg.SecurityRules += New-AzNetworkSecurityRuleConfig -Name "allow-nfs-from-client" -Access Allow -Protocol Tcp -Direction Inbound -Priority 120 `
  -SourceAddressPrefix $clientPrivateIp -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 2049
$serverNsg | Set-AzNetworkSecurityGroup | Out-Null

# ---------- DNS ellenőrzés ----------
$serverPublicIp = (Get-AzPublicIpAddress -ResourceGroupName $ResourceGroupName -Name $serverPip.Name).IpAddress
Write-Host "Server public IP: $serverPublicIp"
Write-Host "Várakozás a DNS feloldásra: $DomainName → $serverPublicIp ..."
while ($true) {
  try {
    $resolved = (Resolve-DnsName -Name $DomainName -Type A -ErrorAction Stop).IPAddress
    if ($resolved -eq $serverPublicIp) { break }
    Write-Host "Jelenleg: $resolved, várakozás..."
  } catch { Write-Host "Még nincs A rekord, várakozás..." }
  Start-Sleep -Seconds 15
}

# ---------- IDEIGLENES 443 megnyitás (NSG) a tanúsítványhoz ----------
$serverNsg = Get-AzNetworkSecurityGroup -Name "nsg-$ServerVmName" -ResourceGroupName $ResourceGroupName
# Priority 90 -> megelőzi a Corvinus-specifikus szabályt
$tempRule = New-AzNetworkSecurityRuleConfig -Name "temp-allow-443-any" -Access Allow -Protocol Tcp -Direction Inbound -Priority 90 `
  -SourceAddressPrefix * -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 443
$serverNsg.SecurityRules += $tempRule
$serverNsg | Set-AzNetworkSecurityGroup | Out-Null

# ---------- Certbot futtatás a VM-en (UFW ideiglenes nyitás + TLS-ALPN-01) ----------
$script = @"
set -e
# UFW: ideiglenes 443 engedély mindenhonnan
ufw delete allow from $CorvinusCidr to any port 443 proto tcp || true
ufw allow 443/tcp
# Let’s Encrypt (443-on, port 80 továbbra is zárt)
certbot --apache --preferred-challenges tls-alpn-01 -d $DomainName --agree-tos -m admin@$DomainName --non-interactive --redirect
# UFW visszaállítása
ufw delete allow 443/tcp
ufw allow from $CorvinusCidr to any port 443 proto tcp
"@

Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -Name $ServerVmName -CommandId 'RunShellScript' -ScriptString $script | Out-Null

# ---------- Ideiglenes NSG szabály eltávolítása ----------
$serverNsg = Get-AzNetworkSecurityGroup -Name "nsg-$ServerVmName" -ResourceGroupName $ResourceGroupName
$serverNsg.SecurityRules = $serverNsg.SecurityRules | Where-Object { $_.Name -ne "temp-allow-443-any" }
$serverNsg | Set-AzNetworkSecurityGroup | Out-Null

# ---------- Kimenet ----------
"`nKÉSZ! WordPress: https://$DomainName/wordpress"
"Server public IP  : $serverPublicIp"
"Server private IP : $serverPrivateIp"
"Client private IP : $clientPrivateIp"
"WP DB user       : wp_user"
"WP DB password   : $WpDbPassword"
