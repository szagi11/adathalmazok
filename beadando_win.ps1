
<# 
 Azure architektúra: Windows Server 2022 + Windows 11
 - Szerver: SMB fileszerver (C:\files01 -> \\server\files01), IIS csak HTTPS, OpenSSH
 - Kliens: Z: meghajtó -> \\<serverPrivIP>\files01
 - NSG: Corvinus (146.110.0.0/16) -> csak 443; kliens IP -> 22/3389/445/443
 - Kliensnek nincs publikus IP
#>

param(
  [string]$SubscriptionId = "643b6c9a-f082-4e5d-a8a5-e2dde8f0ec61",
  [string]$ResourceGroupName = "rg-win-wp-files-demo",
  [string]$Location = "westeurope",

  # Hálózat
  [string]$VNetName = "vnet-win",
  [string]$SubnetName = "subnet-win",
  [string]$VNetAddressPrefix = "10.30.0.0/16",
  [string]$SubnetPrefix = "10.30.1.0/24",

  # VM-ek
  [string]$ServerVmName = "srv-win2022",
  [string]$ClientVmName = "cli-win11",
  [string]$ServerSize = "Standard_B2ms",
  [string]$ClientSize = "Standard_B2ms",

  # Helyi admin a létrehozáshoz (külön a 'szagi' useren felül)
  [string]$AdminUser = "azureadmin",
  [securestring]$AdminPassword = (ConvertTo-SecureString "ChangeMe!123" -AsPlainText -Force),

  # 'szagi' felhasználó közös jelszó mindkét gépen
  [securestring]$SzagiPassword = (ConvertTo-SecureString "P@ssw0rd!123" -AsPlainText -Force)
)

if ($SubscriptionId) { Set-AzContext -SubscriptionId $SubscriptionId }

# Corvinus CIDR (publikus): csak HTTPS nyitás erre a tartományra
$CorvinusCidr = "146.110.0.0/16"  # BCE hálózat – publikus tartomány

# ---------- Resource Group ----------
New-AzResourceGroup -Name $ResourceGroupName -Location $Location | Out-Null

# ---------- VNet / Subnet ----------
$vnet = New-AzVirtualNetwork -Name $VNetName -ResourceGroupName $ResourceGroupName -Location $Location -AddressPrefix $VNetAddressPrefix
$vnet | Add-AzVirtualNetworkSubnetConfig -Name $SubnetName -AddressPrefix $SubnetPrefix | Set-AzVirtualNetwork | Out-Null
$subnetObj = (Get-AzVirtualNetwork -Name $VNetName -ResourceGroupName $ResourceGroupName).Subnets | Where-Object {$_.Name -eq $SubnetName}

# ---------- NSG-k ----------
$serverNsg = New-AzNetworkSecurityGroup -Name "nsg-$ServerVmName" -ResourceGroupName $ResourceGroupName -Location $Location
$clientNsg = New-AzNetworkSecurityGroup -Name "nsg-$ClientVmName" -ResourceGroupName $ResourceGroupName -Location $Location
$serverNsg | Set-AzNetworkSecurityGroup | Out-Null
$clientNsg | Set-AzNetworkSecurityGroup | Out-Null

# ---------- Publikus IP csak szervernek ----------
$serverPip = New-AzPublicIpAddress -Name "pip-$ServerVmName" -ResourceGroupName $ResourceGroupName -Location $Location -AllocationMethod Static -Sku Standard

# ---------- NIC-ek ----------
$serverNic = New-AzNetworkInterface -Name "nic-$ServerVmName" -ResourceGroupName $ResourceGroupName -Location $Location `
  -Subnet $subnetObj -NetworkSecurityGroup $serverNsg -PublicIpAddress $serverPip

$clientNic = New-AzNetworkInterface -Name "nic-$ClientVmName" -ResourceGroupName $ResourceGroupName -Location $Location `
  -Subnet $subnetObj -NetworkSecurityGroup $clientNsg

# Privát IP-k
$serverPrivateIp = $serverNic.IpConfigurations[0].PrivateIpAddress
$clientPrivateIp = $clientNic.IpConfigurations[0].PrivateIpAddress

# ---------- Szerver VM (Windows Server 2022) ----------
$serverVmCfg = New-AzVMConfig -VMName $ServerVmName -VMSize $ServerSize
$serverVmCfg = Set-AzVMOperatingSystem -VM $serverVmCfg -Windows -ComputerName $ServerVmName -Credential (New-Object System.Management.Automation.PSCredential ($AdminUser, $AdminPassword)) -ProvisionVMAgent -EnableAutoUpdate
$serverVmCfg = Set-AzVMSourceImage -VM $serverVmCfg -PublisherName "MicrosoftWindowsServer" -Offer "WindowsServer" -Skus "2022-datacenter-azure-edition" -Version "latest"
$serverVmCfg = Add-AzVMNetworkInterface -VM $serverVmCfg -Id $serverNic.Id
New-AzVM -ResourceGroupName $ResourceGroupName -Location $Location -VM $serverVmCfg | Out-Null

# ---------- Kliens VM (Windows 11 Pro) ----------
$clientVmCfg = New-AzVMConfig -VMName $ClientVmName -VMSize $ClientSize
$clientVmCfg = Set-AzVMOperatingSystem -VM $clientVmCfg -Windows -ComputerName $ClientVmName -Credential (New-Object System.Management.Automation.PSCredential ($AdminUser, $AdminPassword)) -ProvisionVMAgent -EnableAutoUpdate
$clientVmCfg = Set-AzVMSourceImage -VM $clientVmCfg -PublisherName "MicrosoftWindowsDesktop" -Offer "Windows-11" -Skus "win11-22h2-pro" -Version "latest"
$clientVmCfg = Add-AzVMNetworkInterface -VM $clientVmCfg -Id $clientNic.Id
New-AzVM -ResourceGroupName $ResourceGroupName -Location $Location -VM $clientVmCfg | Out-Null

# ---------- NSG finomhangolás (szerver): csak szükséges portok ----------
# 443 publikus csak Corvinusból
$ruleHttpsCorv = New-AzNetworkSecurityRuleConfig -Name "allow-https-corvinus" -Access Allow -Protocol Tcp -Direction Inbound -Priority 100 `
  -SourceAddressPrefix $CorvinusCidr -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 443
# Kliens IP -> szerver: SSH(22), RDP(3389), SMB(445), HTTPS(443)
$ruleSshClient = New-AzNetworkSecurityRuleConfig -Name "allow-ssh-from-client" -Access Allow -Protocol Tcp -Direction Inbound -Priority 110 `
  -SourceAddressPrefix $clientPrivateIp -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 22
$ruleRdpClient = New-AzNetworkSecurityRuleConfig -Name "allow-rdp-from-client" -Access Allow -Protocol Tcp -Direction Inbound -Priority 120 `
  -SourceAddressPrefix $clientPrivateIp -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 3389
$ruleSmbClient = New-AzNetworkSecurityRuleConfig -Name "allow-smb-from-client" -Access Allow -Protocol Tcp -Direction Inbound -Priority 130 `
  -SourceAddressPrefix $clientPrivateIp -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 445
$ruleHttpsClient = New-AzNetworkSecurityRuleConfig -Name "allow-https-from-client" -Access Allow -Protocol Tcp -Direction Inbound -Priority 140 `
  -SourceAddressPrefix $clientPrivateIp -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 443

$serverNsg = Get-AzNetworkSecurityGroup -Name "nsg-$ServerVmName" -ResourceGroupName $ResourceGroupName
$serverNsg.SecurityRules += $ruleHttpsCorv
$serverNsg.SecurityRules += $ruleSshClient
$serverNsg.SecurityRules += $ruleRdpClient
$serverNsg.SecurityRules += $ruleSmbClient
$serverNsg.SecurityRules += $ruleHttpsClient
$serverNsg | Set-AzNetworkSecurityGroup | Out-Null

# ---------- OS konfigurációk futtatása (RunCommand) ----------
# Közös hasznos segédfüggvény – tiszta szöveggé alakítja a SecureStringet
function Convert-SecureToPlain([securestring]$sec) {
  $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
  $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
  [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
  return $plain
}
$SzagiPlain = Convert-SecureToPlain $SzagiPassword

# --- Szerver: user + SMB + IIS + OpenSSH + WF szabályok ---
$serverScript = @"
# Szagi felhasználó
net user szagi "$SzagiPlain" /add
net localgroup Administrators szagi /add

# Megosztás
New-Item -ItemType Directory -Path 'C:\files01' -Force | Out-Null
icacls 'C:\files01' /grant szagi:(OI)(CI)F /T
# SMB share – teljes hozzáférés 'szagi' számára
if (-not (Get-SmbShare | Where-Object Name -eq 'files01')) {
  New-SmbShare -Name 'files01' -Path 'C:\files01' -FullAccess 'szagi'
}

# IIS csak HTTPS
Import-Module ServerManager
Install-WindowsFeature -Name Web-Server -IncludeManagementTools
Import-Module WebAdministration

# Ön-aláírt cert (demóhoz); cserélhető később vállalati tanúsítványra
\$cert = New-SelfSignedCertificate -DnsName "$($ServerVmName).local" -CertStoreLocation Cert:\LocalMachine\My
# https binding felvétele a Default Web Site-ra
Remove-WebBinding -Name 'Default Web Site' -Protocol 'http' -Port 80 -ErrorAction SilentlyContinue
New-WebBinding -Name 'Default Web Site' -Protocol 'https' -Port 443
# Cert hozzárendelése (SNI nélkül, egyszerű kötés)
\$thumb = \$cert.Thumbprint
Import-Module IISAdministration
New-IISSiteBinding -Name 'Default Web Site' -BindingInformation '*:443:' -CertificateThumbPrint \$thumb -CertificateStoreName 'My' -Protocol 'https'

# OpenSSH Server
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic

# Windows tűzfal – csak kliens IP és Corvinus tartomány felől
# (Az NSG már szűr, itt extra finomhangolás)
New-NetFirewallRule -DisplayName 'Allow SSH from client'   -Direction Inbound -Action Allow -Protocol TCP -LocalPort 22   -RemoteAddress $clientPrivateIp
# RDP: letiltjuk a default "Remote Desktop - User Mode (TCP-In)" szabályokat, helyette csak kliens IP
Get-NetFirewallRule -DisplayName 'Remote Desktop - User Mode (TCP-In)' | Disable-NetFirewallRule
New-NetFirewallRule -DisplayName 'Allow RDP from client'   -Direction Inbound -Action Allow -Protocol TCP -LocalPort 3389 -RemoteAddress $clientPrivateIp
New-NetFirewallRule -DisplayName 'Allow SMB from client'   -Direction Inbound -Action Allow -Protocol TCP -LocalPort 445  -RemoteAddress $clientPrivateIp
New-NetFirewallRule -DisplayName 'Allow HTTPS from client' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 443  -RemoteAddress $clientPrivateIp
# HTTPS Corvinus felől (WF nem támogat CIDR-t minden esetben, de az NSG már szűr. Opcionálisan hagyjuk általánosra a WF-ben.)
"@

Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -Name $ServerVmName -CommandId 'RunPowerShellScript' -ScriptString $serverScript | Out-Null

# --- Kliens: user + Z: meghajtó csatolás ---
$clientScript = @"
# Szagi felhasználó
net user szagi "$SzagiPlain" /add
net localgroup Administrators szagi /add

# Z: meghajtó -> \\<serverPrivIP>\files01 (persistens)
cmd /c "net use Z: \\$serverPrivateIp\files01 $SzagiPlain /user:szagi /persistent:yes"
"@

Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -Name $ClientVmName -CommandId 'RunPowerShellScript' -ScriptString $clientScript | Out-Null

# ---------- Kimenet ----------
$serverPublicIp = (Get-AzPublicIpAddress -ResourceGroupName $ResourceGroupName -Name $serverPip.Name).IpAddress
"`nKÉSZ."
"Server public IP  : $serverPublicIp"
"Server private IP : $serverPrivateIp"
"Client private IP : $clientPrivateIp"
"SMB share         : \\$serverPrivateIp\files01  (Z: a kliensen)"
