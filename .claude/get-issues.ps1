param([string]$Token = $env:GITHUB_TOKEN)
$headers = @{
    Authorization          = "Bearer $Token"
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
}
$issues = Invoke-RestMethod -Uri 'https://api.github.com/repos/michaellwest/PrecisionScheduler/issues?state=open&per_page=50' -Headers $headers
$issues | Select-Object number, title | Format-Table -AutoSize
