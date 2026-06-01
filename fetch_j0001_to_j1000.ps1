$summariesJsonPath = 'C:\Users\Lenovo\OneDrive\Desktop\New_Horizon_Library\summaries.json'
$inventoryCsvPath  = 'C:\Users\Lenovo\OneDrive\Desktop\New_Horizon_Library\inventory_data.csv'

# 1. Load existing summaries
$summaryMap = @{}
if (Test-Path $summariesJsonPath) {
    # Using specific UTF-8 Encoding loading to avoid issues
    $json = Get-Content $summariesJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($prop in $json.PSObject.Properties) {
        $summaryMap[$prop.Name] = $prop.Value
    }
    Write-Host ("Loaded " + $summaryMap.Count + " existing summaries.")
}

# 2. Build map of acc_no -> title for J0001-J1000
$targetTitles = @{} # title -> author
$csvLines = Get-Content $inventoryCsvPath

$headers = $csvLines[0] -split ',(?=(?:[^"]*"[^"]*")*[^"]*$)' | ForEach-Object { $_.Trim('"').Trim() }
$titleIdx = [array]::IndexOf($headers, 'Book Name(*)')
$accIdx   = [array]::IndexOf($headers, 'Accession Number')
$authIdx  = [array]::IndexOf($headers, 'Author')

if ($titleIdx -lt 0 -or $accIdx -lt 0) {
    Write-Host "Required columns not found in inventory_data.csv!"
    exit 1
}

for ($i = 1; $i -lt $csvLines.Count; $i++) {
    $line = $csvLines[$i]
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    
    $cols = $line -split ',(?=(?:[^"]*"[^"]*")*[^"]*$)'
    
    if ($cols.Count -gt [Math]::Max($titleIdx, $accIdx)) {
        $title = $cols[$titleIdx].Trim('"').Trim()
        $accNo = $cols[$accIdx].Trim('"').Trim()
        $author = if ($authIdx -ge 0 -and $cols.Count -gt $authIdx) { $cols[$authIdx].Trim('"').Trim() } else { '' }
        
        # Check if it's within J0001 to J1000
        if ($accNo -match '^J\d+$' -and $title.Length -gt 1 -and $title -ne 'XYZ') {
            $num = [int]($accNo -replace '^J', '')
            if ($num -ge 1 -and $num -le 1000) {
                # Add to target titles if we don't have a summary for it
                if (-not $summaryMap.ContainsKey($title)) {
                    $targetTitles[$title] = $author
                }
            }
        }
    }
}

Write-Host ("Found " + $targetTitles.Count + " books in J0001-J1000 missing summaries.")

# 3. Define fetching functions
function Get-WikiDirect($title) {
    try {
        $encoded = [uri]::EscapeDataString($title.Trim())
        $url = 'https://en.wikipedia.org/api/rest_v1/page/summary/' + $encoded
        $res = Invoke-RestMethod -Uri $url -TimeoutSec 5 -ErrorAction Stop
        if ($res.extract -and $res.extract.Length -gt 30) {
            $desc = $res.extract
            if ($desc.Length -gt 400) { $desc = $desc.Substring(0, 397) + '...' }
            return $desc
        }
    } catch { }
    return $null
}

function Search-Wiki($title) {
    try {
        $encoded = [uri]::EscapeDataString($title.Trim() + ' book')
        $searchUrl = 'https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=' + $encoded + '&srlimit=1&format=json'
        $searchRes = Invoke-RestMethod -Uri $searchUrl -TimeoutSec 5 -ErrorAction Stop
        if ($searchRes.query.search.Count -gt 0) {
            $pageTitle = $searchRes.query.search[0].title
            $encodedPage = [uri]::EscapeDataString($pageTitle)
            $pageUrl = 'https://en.wikipedia.org/api/rest_v1/page/summary/' + $encodedPage
            $pageRes = Invoke-RestMethod -Uri $pageUrl -TimeoutSec 5 -ErrorAction Stop
            if ($pageRes.extract -and $pageRes.extract.Length -gt 50) {
                $desc = $pageRes.extract
                if ($desc.Length -gt 400) { $desc = $desc.Substring(0, 397) + '...' }
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
        $res = Invoke-RestMethod -Uri $url -TimeoutSec 5 -ErrorAction Stop
        if ($res.items.Count -gt 0 -and $res.items[0].volumeInfo.description) {
            $desc = $res.items[0].volumeInfo.description
            if ($desc.Length -gt 400) { $desc = $desc.Substring(0, 397) + '...' }
            return $desc
        }
    } catch { }
    return $null
}

# 4. Fetch missing summaries
$newFound = 0
$i = 0

foreach ($kvp in $targetTitles.GetEnumerator()) {
    $i++
    $title  = $kvp.Key
    $author = $kvp.Value

    $pct = [math]::Round(($i / $targetTitles.Count) * 100)
    Write-Progress -Activity 'Multi-source API fetch' -Status ("[$i/" + $targetTitles.Count + "] $title") -PercentComplete $pct

    $summary = Get-WikiDirect $title
    if (-not $summary) {
        $summary = Search-Wiki $title
    }
    if (-not $summary) {
        $summary = Get-GoogleBooks $title $author
    }

    if ($summary -and $summary.Length -gt 15) {
        $summaryMap[$title] = $summary
        $newFound++
        Write-Host (" + Found: " + $title)
    }

    # API limits sleep
    Start-Sleep -Milliseconds 150
}

Write-Progress -Activity 'Multi-source API fetch' -Completed

Write-Host "-----------------------------"
Write-Host "New summaries found: $newFound"
Write-Host "Total summaries now: " $summaryMap.Count

# 5. Save back to summaries.json safely
$jsonOut = $summaryMap | ConvertTo-Json -Compress
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($summariesJsonPath, $jsonOut, $utf8NoBom)

Write-Host "Saved successfully!"
