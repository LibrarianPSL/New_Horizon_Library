# Batch fetch summaries from OpenLibrary for all books
# Outputs: summaries.json - a lookup table of title -> summary

$outputFile = "c:\Users\Lenovo\OneDrive\Desktop\New_Horizon_Library\summaries.json"
$summaryMap = @{}
$missing = @()
$found = 0
$total = 0

function Get-BookSummary($title) {
    try {
        $cleanTitle = $title -replace '[\[\]\(\)\*:;]', ' '
        $encoded = [uri]::EscapeDataString($cleanTitle.Trim())
        $searchUrl = "https://openlibrary.org/search.json?title=$encoded&limit=1"
        $searchRes = Invoke-RestMethod -Uri $searchUrl -TimeoutSec 10

        if ($searchRes.docs.Count -gt 0) {
            $key = $searchRes.docs[0].key
            $workUrl = "https://openlibrary.org$key.json"
            $workRes = Invoke-RestMethod -Uri $workUrl -TimeoutSec 10

            $desc = $null
            if ($workRes.description -is [string]) {
                $desc = $workRes.description
            } elseif ($workRes.description.value) {
                $desc = $workRes.description.value
            }

            if ($desc) {
                # Take just first paragraph and truncate
                $desc = ($desc -split "`r`n|`n")[0].Trim()
                if ($desc.Length -gt 300) { $desc = $desc.Substring(0, 297) + "..." }
                return $desc
            }
        }
    } catch {
        # Silently skip errors
    }
    return $null
}

# Parse main inventory CSV
$mainContent = Get-Content "c:\Users\Lenovo\OneDrive\Desktop\New_Horizon_Library\inventory_data.csv"
$headers = $mainContent[0] -split ',' | ForEach-Object { $_.Trim('"') }
$titleIdx = [array]::IndexOf($headers, "Book Name(*)")

# Collect unique titles
$allTitles = [System.Collections.Generic.HashSet[string]]::new()
for ($i = 1; $i -lt $mainContent.Count; $i++) {
    $row = $mainContent[$i] -split ',(?=(?:[^"]*"[^"]*")*[^"]*$)'
    if ($row.Count -gt $titleIdx) {
        $t = $row[$titleIdx].Trim('"').Trim()
        if ($t -and $t -ne "XYZ" -and $t.Length -gt 2) {
            [void]$allTitles.Add($t)
        }
    }
}

# Parse reference inventory CSV  
$refContent = Get-Content "c:\Users\Lenovo\OneDrive\Desktop\New_Horizon_Library\reference_data.csv"
$refHeaders = $refContent[0] -split ',' | ForEach-Object { $_.Trim('"') }
$refTitleIdx = [array]::IndexOf($refHeaders, "Book Name(*)")
if ($refTitleIdx -lt 0) { $refTitleIdx = [array]::IndexOf($refHeaders, "Title") }

for ($i = 1; $i -lt $refContent.Count; $i++) {
    $row = $refContent[$i] -split ',(?=(?:[^"]*"[^"]*")*[^"]*$)'
    if ($row.Count -gt $refTitleIdx) {
        $t = $row[$refTitleIdx].Trim('"').Trim()
        if ($t -and $t.Length -gt 2) {
            [void]$allTitles.Add($t)
        }
    }
}

$total = $allTitles.Count
Write-Host "Found $total unique book titles. Starting summary fetch..."
Write-Host "This may take a while - fetching from OpenLibrary..."

$i = 0
foreach ($title in $allTitles) {
    $i++
    $pct = [math]::Round(($i / $total) * 100)
    Write-Progress -Activity "Fetching summaries" -Status "$i/$total - $title" -PercentComplete $pct

    if (-not $summaryMap.ContainsKey($title)) {
        $summary = Get-BookSummary $title
        if ($summary) {
            $summaryMap[$title] = $summary
            $found++
        } else {
            $missing += $title
        }
    }

    # Small delay to be respectful of the API
    Start-Sleep -Milliseconds 300
    
    # Save progress every 50 books in case of interruption
    if ($i % 50 -eq 0) {
        $summaryMap | ConvertTo-Json -Compress | Out-File $outputFile -Encoding UTF8
        Write-Host "[$i/$total] Saved progress... Found $found summaries so far."
    }
}

# Final save
$summaryMap | ConvertTo-Json -Compress | Out-File $outputFile -Encoding UTF8

Write-Host "`n=== DONE ==="
Write-Host "Total unique books: $total"
Write-Host "Summaries found:    $found"
Write-Host "Missing summaries:  $($missing.Count)"
Write-Host ""
Write-Host "Books WITHOUT summaries:"
$missing | ForEach-Object { Write-Host "  - $_" }
Write-Host ""
Write-Host "Saved to: $outputFile"
