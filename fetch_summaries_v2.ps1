$outputFile = 'c:\Users\Lenovo\OneDrive\Desktop\New_Horizon_Library\summaries.json'

$summaryMap = @{}
if (Test-Path $outputFile) {
    $existing = Get-Content $outputFile -Raw | ConvertFrom-Json
    foreach ($prop in $existing.PSObject.Properties) {
        $summaryMap[$prop.Name] = $prop.Value
    }
    Write-Host ('Loaded ' + $summaryMap.Count + ' existing summaries.')
}

function Get-WikiDirect($title) {
    try {
        $encoded = [uri]::EscapeDataString($title.Trim())
        $url = 'https://en.wikipedia.org/api/rest_v1/page/summary/' + $encoded
        $res = Invoke-RestMethod -Uri $url -TimeoutSec 8 -ErrorAction Stop
        if ($res.extract -and $res.extract.Length -gt 30) {
            $desc = $res.extract
            if ($desc.Length -gt 300) { $desc = $desc.Substring(0, 297) + '...' }
            return $desc
        }
    } catch { }
    return $null
}

function Search-Wiki($title) {
    try {
        $encoded = [uri]::EscapeDataString($title.Trim() + ' book')
        $searchUrl = 'https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=' + $encoded + '&srlimit=1&format=json'
        $searchRes = Invoke-RestMethod -Uri $searchUrl -TimeoutSec 8 -ErrorAction Stop
        if ($searchRes.query.search.Count -gt 0) {
            $pageTitle = $searchRes.query.search[0].title
            $encodedPage = [uri]::EscapeDataString($pageTitle)
            $pageUrl = 'https://en.wikipedia.org/api/rest_v1/page/summary/' + $encodedPage
            $pageRes = Invoke-RestMethod -Uri $pageUrl -TimeoutSec 8 -ErrorAction Stop
            if ($pageRes.extract -and $pageRes.extract.Length -gt 50) {
                $desc = $pageRes.extract
                if ($desc.Length -gt 300) { $desc = $desc.Substring(0, 297) + '...' }
                return $desc
            }
        }
    } catch { }
    return $null
}

function Get-GoogleBooks($title, $author) {
    try {
        $q = [uri]::EscapeDataString(($title + ' ' + $author).Trim())
        $url = 'https://www.googleapis.com/books/v1/volumes?q=' + $q + '&maxResults=1'
        $res = Invoke-RestMethod -Uri $url -TimeoutSec 8 -ErrorAction Stop
        if ($res.items.Count -gt 0 -and $res.items[0].volumeInfo.description) {
            $desc = $res.items[0].volumeInfo.description
            if ($desc.Length -gt 300) { $desc = $desc.Substring(0, 297) + '...' }
            return $desc
        }
    } catch { }
    return $null
}

$missingTitles = [System.Collections.Generic.Dictionary[string,string]]::new()

function Add-MissingFromCsv($csvPath) {
    $lines = Get-Content $csvPath
    $headers = $lines[0] -split ',(?=(?:[^"]*"[^"]*")*[^"]*$)' | ForEach-Object { $_.Trim('"') }
    $titleIdx  = [array]::IndexOf($headers, 'Book Name(*)')
    $authorIdx = [array]::IndexOf($headers, 'Author')
    if ($titleIdx -lt 0) { return }
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $row = $lines[$i] -split ',(?=(?:[^"]*"[^"]*")*[^"]*$)'
        if ($row.Count -gt $titleIdx) {
            $t = $row[$titleIdx].Trim('"').Trim()
            $a = if ($authorIdx -ge 0 -and $row.Count -gt $authorIdx) { $row[$authorIdx].Trim('"').Trim() } else { '' }
            if ($t -and $t -ne 'XYZ' -and $t.Length -gt 2 -and -not $summaryMap.ContainsKey($t)) {
                if (-not $missingTitles.ContainsKey($t)) { $missingTitles[$t] = $a }
            }
        }
    }
}

Add-MissingFromCsv 'c:\Users\Lenovo\OneDrive\Desktop\New_Horizon_Library\inventory_data.csv'
Add-MissingFromCsv 'c:\Users\Lenovo\OneDrive\Desktop\New_Horizon_Library\reference_data.csv'

Write-Host ('Books still missing summaries: ' + $missingTitles.Count)
Write-Host 'Starting multi-source enrichment (Wikipedia + Google Books fallback)...'

$newFound = 0
$i = 0
$stillMissing = @()

foreach ($kvp in $missingTitles.GetEnumerator()) {
    $i++
    $title  = $kvp.Key
    $author = $kvp.Value

    $pct = [math]::Round(($i / $missingTitles.Count) * 100)
    Write-Progress -Activity 'Multi-source fetch' -Status ('['+ $i + '/' + $missingTitles.Count + '] ' + $title) -PercentComplete $pct

    $summary = $null

    $summary = Get-WikiDirect $title

    if (-not $summary) {
        Start-Sleep -Milliseconds 100
        $summary = Search-Wiki $title
    }

    if (-not $summary -and ($i % 3 -eq 0)) {
        Start-Sleep -Milliseconds 300
        $summary = Get-GoogleBooks $title $author
    }

    if ($summary) {
        $summaryMap[$title] = $summary
        $newFound++
    } else {
        $stillMissing += $title
    }

    Start-Sleep -Milliseconds 200

    if ($i % 100 -eq 0) {
        $summaryMap | ConvertTo-Json -Compress | Out-File $outputFile -Encoding UTF8
        Write-Host ('[' + $i + '/' + $missingTitles.Count + '] Saved — Total summaries now: ' + $summaryMap.Count)
    }
}

$summaryMap | ConvertTo-Json -Compress | Out-File $outputFile -Encoding UTF8

Write-Host ''
Write-Host '==================================='
Write-Host '       FINAL SUMMARY REPORT'
Write-Host '==================================='
Write-Host ('New summaries found this run: ' + $newFound)
Write-Host ('Total summaries in file:      ' + $summaryMap.Count)
Write-Host ('Still missing:                ' + $stillMissing.Count)
Write-Host ''
Write-Host 'Books still without any summary:'
$stillMissing | ForEach-Object { Write-Host ('  - ' + $_) }
