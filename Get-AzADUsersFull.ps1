Function Get-AzureADUsersFull{
param(
[Parameter(Position = 0, Mandatory = $true)]
[object[]]
$Tokens = "",
[Parameter(Mandatory=$false)]
[string]$Resource = "https://graph.microsoft.com/",
[Parameter(Mandatory=$false)]
[ValidateSet('Mac','Windows','AndroidMobile','iPhone')]
[String]$Device = "Windows",
[Parameter(Mandatory=$false)]
[ValidateSet('Android','IE','Chrome','Firefox','Edge','Safari')]
[String]$Browser = "Edge",
[Parameter(Mandatory=$False)]
[String]$ClientID = "d3590ed6-52b3-4102-aeff-aad2292ab01c",
[Parameter(Mandatory = $true)]
[string]
$outfile = "AzureADUsersFull.csv",
[switch]
$GraphRun
)
$access_token = $tokens.access_token
if ($Device) {
if ($Browser) {
$UserAgent = Invoke-ForgeUserAgent -Device $Device -Browser $Browser
}
else {
$UserAgent = Invoke-ForgeUserAgent -Device $Device
}
}
else {
if ($Browser) {
$UserAgent = Invoke-ForgeUserAgent -Browser $Browser
}
else {
$UserAgent = Invoke-ForgeUserAgent
}
}
if(!$GraphRun){
Write-Host "[*] Gathering all user attributes from the tenant."
}

# beta endpoint + select=* returns the full user schema, v1.0 does not support this
$usersEndpoint = "https://graph.microsoft.com/beta/users?`$select=*"
$userlist = @()
do{
try{
$Headers = @{
"Authorization" = "Bearer $access_token"
"User-Agent" = $UserAgent
}

$request = Invoke-WebRequest -UseBasicParsing -Method GET -Uri $usersEndpoint -Headers $Headers
}catch {
if($_.Exception.Response.StatusCode.value__ -match "429"){
Write-Host -ForegroundColor red "[*] Being throttled... sleeping 5 seconds"
Start-Sleep -Seconds 5
continue
}
else{
Write-Host -ForegroundColor red ("[!] Error: " + $_.Exception.Message)
break
}
}
$out = $request.Content | ConvertFrom-Json
$userlist += $out.value
if ($out.'@odata.nextLink') {
if(!$GraphRun){
Write-Host "[*] Gathering more users..."
}
$usersEndpoint = $out.'@odata.nextLink'
}
else {
break
}
} while ($true)

if(!$GraphRun){
Write-Host -ForegroundColor green ("Discovered " + $userlist.count + " users")
}

# flatten any array-type properties so Export-Csv doesn't just dump "System.Object[]"
$props = $userlist | Select-Object -First 1 | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name
$userlist | ForEach-Object {
$u = $_
foreach($p in $props){
if($u.$p -is [System.Array]){
$u.$p = ($u.$p | ForEach-Object { if($_.PSObject.Properties['skuId']){$_.skuId} else {$_} }) -join ';'
}
elseif($u.$p -is [PSCustomObject]){
$u.$p = ($u.$p | ConvertTo-Json -Compress)
}
}
}

$userlist | Export-Csv -Path $outfile -NoTypeInformation -Encoding UTF8
if(!$GraphRun){
Write-Host -ForegroundColor green ("[*] Full attribute data written to " + $outfile)
}
}
