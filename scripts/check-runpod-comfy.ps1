param(
    [string]$PodId,
    [string]$TemplateId = "mwdfwag9jj",
    [string]$ExpectedPorts = "8188/http,8189/http",
    [string]$ExpectedVolumeId = "ubhvpibs60",
    [int]$TimeoutSec = 20,
    [switch]$SkipLocal
)

$ErrorActionPreference = "Stop"

function Write-Check {
    param(
        [string]$Name,
        [bool]$Ok,
        [string]$Detail = ""
    )

    $status = if ($Ok) { "OK" } else { "FAIL" }
    if ($Detail) {
        Write-Host "[$status] $Name - $Detail"
    } else {
        Write-Host "[$status] $Name"
    }

    if (-not $Ok) {
        throw $Name
    }
}

function Invoke-RunPodGraphQL {
    param(
        [string]$Query,
        [hashtable]$Variables = @{}
    )

    if (-not $env:RUNPOD_API_KEY) {
        throw "RUNPOD_API_KEY is not set."
    }

    $body = @{
        query = $Query
        variables = $Variables
    } | ConvertTo-Json -Depth 20

    Invoke-RestMethod `
        -Method Post `
        -Uri "https://api.runpod.io/graphql" `
        -Headers @{ Authorization = "Bearer $env:RUNPOD_API_KEY" } `
        -ContentType "application/json" `
        -Body $body
}

function Invoke-JsonGet {
    param([string]$Url)

    Invoke-RestMethod `
        -Uri $Url `
        -Method Get `
        -TimeoutSec $TimeoutSec `
        -Headers @{ "User-Agent" = "wan22-runpod-checker/1.0" }
}

function Invoke-TextGet {
    param([string]$Url)

    $response = Invoke-RestMethod `
        -Uri $Url `
        -Method Get `
        -TimeoutSec $TimeoutSec `
        -Headers @{ "User-Agent" = "wan22-runpod-checker/1.0" }
    [string]$response
}

function Test-RunPodWebSocket {
    param([string]$PodId)

    $clientId = [guid]::NewGuid().ToString("N")
    $uri = [Uri]"wss://$PodId-8188.proxy.runpod.net/ws?clientId=$clientId"
    $socket = [System.Net.WebSockets.ClientWebSocket]::new()
    $connected = $false
    try {
        $cancel = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSec))
        $null = $socket.ConnectAsync($uri, $cancel.Token).GetAwaiter().GetResult()
        $connected = $socket.State -eq [System.Net.WebSockets.WebSocketState]::Open
    } finally {
        if ($socket.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            try {
                $null = $socket.CloseOutputAsync(
                    [System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure,
                    "done",
                    [Threading.CancellationToken]::None
                ).GetAwaiter().GetResult() | Out-Null
            } catch {
                # The upgrade already succeeded; cleanup races should not fail the check.
            }
        }
        $socket.Dispose()
    }
    return $connected
}

if (-not $SkipLocal) {
    try {
        $localStats = Invoke-JsonGet "http://127.0.0.1:8188/system_stats"
        $localSystem = [string]$localStats.system.os
        $localDevices = @($localStats.devices | ForEach-Object { $_.name }) -join ", "
        $looksLikeRunPod = $localSystem -match "linux" -and $localDevices -match "RTX PRO 6000"
        Write-Check "local 127.0.0.1:8188 is not the RunPod proxy target" (-not $looksLikeRunPod) "system=$localSystem devices=$localDevices"
    } catch {
        Write-Host "[WARN] local 127.0.0.1:8188 was not reachable; skipping local Comfy identity check."
    }
}

$templateQuery = @"
query Template(`$id: String!) {
  podTemplate(id: `$id) {
    id
    name
    imageName
    ports
    volumeMountPath
  }
}
"@
$template = (Invoke-RunPodGraphQL -Query $templateQuery -Variables @{ id = $TemplateId }).data.podTemplate
Write-Check "template $TemplateId exists" ($null -ne $template) $template.name
Write-Check "template ports" ($template.ports -eq $ExpectedPorts) $template.ports
Write-Check "template mount path" ($template.volumeMountPath -eq "/workspace") $template.volumeMountPath
Write-Host "[INFO] template image: $($template.imageName)"

$podsQuery = @"
query Pods {
  myself {
    pods {
      id
      name
      desiredStatus
      imageName
      networkVolume { id name }
      runtime { ports { privatePort type } }
    }
  }
}
"@

if (-not $PodId) {
    $pods = (Invoke-RunPodGraphQL -Query $podsQuery).data.myself.pods
    $PodId = @(
        $pods | Where-Object {
            $_.desiredStatus -eq "RUNNING" -and
            $_.imageName -like "ghcr.io/lum3on/wan22-runpod:*" -and
            $_.networkVolume.id -eq $ExpectedVolumeId
        } | Select-Object -First 1
    ).id
}

if (-not $PodId) {
    throw "No running wan22 pod found. Pass -PodId after launching a pod."
}

$pod = @((Invoke-RunPodGraphQL -Query $podsQuery).data.myself.pods | Where-Object { $_.id -eq $PodId } | Select-Object -First 1)[0]
Write-Check "pod $PodId exists" ($null -ne $pod) $pod.name
Write-Check "pod is running" ($pod.desiredStatus -eq "RUNNING") $pod.desiredStatus
Write-Check "pod volume" ($pod.networkVolume.id -eq $ExpectedVolumeId) "$($pod.networkVolume.name) ($($pod.networkVolume.id))"

$podPorts = @($pod.runtime.ports | Where-Object { $_.type -eq "http" } | Sort-Object privatePort | ForEach-Object { "$($_.privatePort)/$($_.type)" })
$hasExpectedPodPorts = @("8188/http", "8189/http") | ForEach-Object { $podPorts -contains $_ }
Write-Check "pod runtime ports include 8188/http and 8189/http" (-not ($hasExpectedPodPorts -contains $false)) ($podPorts -join ",")

$baseUrl = "https://$PodId-8188.proxy.runpod.net"
$html = Invoke-TextGet "$baseUrl/"
Write-Check "RunPod Comfy page" ($html -match "ComfyUI|comfy") "$baseUrl/"

$stats = Invoke-JsonGet "$baseUrl/system_stats"
$statsText = $stats | ConvertTo-Json -Depth 20
Write-Check "RunPod /system_stats" ($statsText -match "Linux" -and $statsText -match "RTX PRO 6000") "Linux + RTX PRO 6000 detected"

$queue = Invoke-JsonGet "$baseUrl/queue"
Write-Check "RunPod /queue" ($null -ne $queue) "queue JSON returned"

$wsOk = Test-RunPodWebSocket -PodId $PodId
Write-Check "RunPod /ws websocket" $wsOk "101 upgrade accepted"

$features = Invoke-JsonGet "$baseUrl/features"
$featuresText = $features | ConvertTo-Json -Depth 20
Write-Check "RunPod /features Manager support" ($featuresText -match "manager" -and $featuresText -match "supports_v4") "Manager feature flags present"

$managerChecks = @(
    "/v2/manager/version",
    "/v2/customnode/installed",
    "/v2/customnode/getmappings",
    "/v2/manager/queue/status"
)

foreach ($path in $managerChecks) {
    $result = Invoke-JsonGet "$baseUrl$path"
    Write-Check "Manager $path" ($null -ne $result) "JSON returned"
}

Write-Host "[OK] RunPod Comfy and Manager checks passed for pod $PodId"
