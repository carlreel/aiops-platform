# aiops-platform one-click start (run as Administrator)
# Keeps WSL alive, starts containers, sets port forwarding, opens browser.
# Stop everything later with:  wsl --shutdown

$ErrorActionPreference = "Continue"
$Distro = "Ubuntu-24.04"
$Proj   = "/opt/aiops-platform"

Write-Host "=== [1/4] Keep WSL resident ===" -ForegroundColor Cyan
$wslClients = @(Get-Process wsl -ErrorAction SilentlyContinue)
if ($wslClients.Count -eq 0) {
    Start-Process -FilePath "wsl.exe" `
        -ArgumentList "-d", $Distro, "-u", "root", "-e", "sleep", "infinity" `
        -WindowStyle Hidden
    Start-Sleep -Seconds 3
    Write-Host "  Resident session started (stop later with: wsl --shutdown)" -ForegroundColor Green
} else {
    Write-Host "  WSL already resident" -ForegroundColor Green
}

Write-Host "=== [2/4] Start containers ===" -ForegroundColor Cyan
wsl -d $Distro -u root bash -c "cd $Proj && docker compose up -d pgvector rag-api" 2>&1 | Out-Null
Start-Sleep -Seconds 10
wsl -d $Distro -u root bash -c "cd $Proj && docker compose ps --format '{{.Name}} {{.Status}}'"

Write-Host "=== [3/4] Configure port forwarding ===" -ForegroundColor Cyan
$ip = (wsl -d $Distro -u root hostname -I).Trim().Split()[0]
Write-Host "  WSL IP: $ip"
netsh interface portproxy delete v4tov4 listenport=8000 listenaddress=127.0.0.1 2>$null | Out-Null
netsh interface portproxy add v4tov4 listenport=8000 listenaddress=127.0.0.1 connectport=8000 connectaddress=$ip | Out-Null
Start-Sleep -Seconds 2

Write-Host "=== [4/4] Health check ===" -ForegroundColor Cyan
try {
    $h = Invoke-RestMethod "http://127.0.0.1:8000/health" -TimeoutSec 15
    Write-Host ("  db=" + $h.db + "  ollama=" + $h.ollama + "  model=" + $h.model + "  chunks=" + $h.chunks) -ForegroundColor Green
    if ($h.db -eq "up" -and $h.ollama -eq "up") {
        Write-Host "  READY: http://localhost:8000/docs" -ForegroundColor Green
        Start-Process "http://localhost:8000/docs"
    }
} catch {
    Write-Host ("  FAILED: " + $_.Exception.Message) -ForegroundColor Red
}

Write-Host ""
Write-Host "Useful commands:" -ForegroundColor Yellow
Write-Host "  stop WSL : wsl --shutdown"
Write-Host "  logs     : wsl -d $Distro -u root bash -c 'docker logs --tail 50 aiops-rag-api'"
