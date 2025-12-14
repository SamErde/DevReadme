# PowerShell version of today.py
# Fine-grained personal access token with All Repositories access:
# Account permissions: read:Followers, read:Starring, read:Watching
# Repository permissions: read:Commit statuses, read:Contents, read:Issues, read:Metadata, read:Pull Requests

$ErrorActionPreference = "Stop"

$HEADERS = @{
    Authorization = "token $env:ACCESS_TOKEN"
    "Content-Type" = "application/json"
}
$USER_NAME = $env:USER_NAME
$QUERY_COUNT = @{
    user_getter = 0
    follower_getter = 0
    graph_repos_stars = 0
    recursive_loc = 0
    graph_commits = 0
    loc_query = 0
}
$OWNER_ID = $null

function Get-SHA256Hash {
    param(
        [string]$InputString
    )
    
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $hasher.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($InputString))
        return -join ($hashBytes | ForEach-Object { $_.ToString("x2") })
    }
    finally {
        $hasher.Dispose()
    }
}

function Get-DailyReadme {
    param(
        [DateTime]$Birthday
    )
    
    $today = Get-Date
    $years = $today.Year - $Birthday.Year
    $months = $today.Month - $Birthday.Month
    $days = $today.Day - $Birthday.Day
    
    if ($days -lt 0) {
        $months--
        $prevMonth = if ($today.Month -eq 1) { 12 } else { $today.Month - 1 }
        $prevYear = if ($today.Month -eq 1) { $today.Year - 1 } else { $today.Year }
        $days += [DateTime]::DaysInMonth($prevYear, $prevMonth)
    }
    if ($months -lt 0) {
        $years--
        $months += 12
    }
    
    $yearPlural = if ($years -ne 1) { "s" } else { "" }
    $monthPlural = if ($months -ne 1) { "s" } else { "" }
    $dayPlural = if ($days -ne 1) { "s" } else { "" }
    $cake = if ($months -eq 0 -and $days -eq 0) { " 🎂" } else { "" }
    
    return "$years year$yearPlural, $months month$monthPlural, $days day$dayPlural$cake"
}

function Invoke-SimpleRequest {
    param(
        [string]$FuncName,
        [string]$Query,
        [hashtable]$Variables
    )
    
    $body = @{
        query = $Query
        variables = $Variables
    } | ConvertTo-Json -Depth 10
    
    try {
        $response = Invoke-RestMethod -Uri "https://api.github.com/graphql" -Method Post -Headers $HEADERS -Body $body
        return $response
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        Write-Error "$FuncName has failed with status code $statusCode : $($_.Exception.Message)"
        throw
    }
}

function Get-GraphCommits {
    param(
        [string]$StartDate,
        [string]$EndDate
    )
    
    $script:QUERY_COUNT.graph_commits++
    
    $query = @"
query(`$start_date: DateTime!, `$end_date: DateTime!, `$login: String!) {
    user(login: `$login) {
        contributionsCollection(from: `$start_date, to: `$end_date) {
            contributionCalendar {
                totalContributions
            }
        }
    }
}
"@
    
    $variables = @{
        start_date = $StartDate
        end_date = $EndDate
        login = $USER_NAME
    }
    
    $result = Invoke-SimpleRequest -FuncName "Get-GraphCommits" -Query $query -Variables $variables
    return [int]$result.data.user.contributionsCollection.contributionCalendar.totalContributions
}

function Get-GraphReposStars {
    param(
        [string]$CountType,
        [string[]]$OwnerAffiliation,
        [string]$Cursor = $null
    )
    
    $script:QUERY_COUNT.graph_repos_stars++
    
    $query = @"
query (`$owner_affiliation: [RepositoryAffiliation], `$login: String!, `$cursor: String) {
    user(login: `$login) {
        repositories(first: 100, after: `$cursor, ownerAffiliations: `$owner_affiliation) {
            totalCount
            edges {
                node {
                    ... on Repository {
                        nameWithOwner
                        stargazers {
                            totalCount
                        }
                    }
                }
            }
            pageInfo {
                endCursor
                hasNextPage
            }
        }
    }
}
"@
    
    $variables = @{
        owner_affiliation = $OwnerAffiliation
        login = $USER_NAME
        cursor = $Cursor
    }
    
    $result = Invoke-SimpleRequest -FuncName "Get-GraphReposStars" -Query $query -Variables $variables
    
    if ($CountType -eq "repos") {
        return $result.data.user.repositories.totalCount
    }
    elseif ($CountType -eq "stars") {
        return Get-StarsCounter -Data $result.data.user.repositories.edges
    }
}

function Get-RecursiveLoc {
    param(
        [string]$Owner,
        [string]$RepoName,
        [array]$Data,
        [array]$CacheComment,
        [int]$AdditionTotal = 0,
        [int]$DeletionTotal = 0,
        [int]$MyCommits = 0,
        [string]$Cursor = $null
    )
    
    $script:QUERY_COUNT.recursive_loc++
    
    $query = @"
query (`$repo_name: String!, `$owner: String!, `$cursor: String) {
    repository(name: `$repo_name, owner: `$owner) {
        defaultBranchRef {
            target {
                ... on Commit {
                    history(first: 100, after: `$cursor) {
                        totalCount
                        edges {
                            node {
                                ... on Commit {
                                    committedDate
                                }
                                author {
                                    user {
                                        id
                                    }
                                }
                                deletions
                                additions
                            }
                        }
                        pageInfo {
                            endCursor
                            hasNextPage
                        }
                    }
                }
            }
        }
    }
}
"@
    
    $variables = @{
        repo_name = $RepoName
        owner = $Owner
        cursor = $Cursor
    }
    
    $body = @{
        query = $query
        variables = $variables
    } | ConvertTo-Json -Depth 10
    
    try {
        $response = Invoke-RestMethod -Uri "https://api.github.com/graphql" -Method Post -Headers $HEADERS -Body $body
        
        if ($response.data.repository.defaultBranchRef -ne $null) {
            return Get-LocCounterOneRepo -Owner $Owner -RepoName $RepoName -Data $Data -CacheComment $CacheComment `
                -History $response.data.repository.defaultBranchRef.target.history `
                -AdditionTotal $AdditionTotal -DeletionTotal $DeletionTotal -MyCommits $MyCommits
        }
        else {
            return 0
        }
    }
    catch {
        Save-ForceCloseFile -Data $Data -CacheComment $CacheComment
        if ($_.Exception.Response.StatusCode.value__ -eq 403) {
            throw "Too many requests in a short amount of time! You've hit the non-documented anti-abuse limit!"
        }
        throw "Get-RecursiveLoc has failed with: $($_.Exception.Message)"
    }
}

function Get-LocCounterOneRepo {
    param(
        [string]$Owner,
        [string]$RepoName,
        [array]$Data,
        [array]$CacheComment,
        $History,
        [int]$AdditionTotal,
        [int]$DeletionTotal,
        [int]$MyCommits
    )
    
    foreach ($node in $History.edges) {
        if ($node.node.author.user -ne $null -and $node.node.author.user.id -eq $script:OWNER_ID.id) {
            $MyCommits++
            $AdditionTotal += $node.node.additions
            $DeletionTotal += $node.node.deletions
        }
    }
    
    if ($History.edges.Count -eq 0 -or -not $History.pageInfo.hasNextPage) {
        return @($AdditionTotal, $DeletionTotal, $MyCommits)
    }
    else {
        return Get-RecursiveLoc -Owner $Owner -RepoName $RepoName -Data $Data -CacheComment $CacheComment `
            -AdditionTotal $AdditionTotal -DeletionTotal $DeletionTotal -MyCommits $MyCommits `
            -Cursor $History.pageInfo.endCursor
    }
}

function Get-LocQuery {
    param(
        [string[]]$OwnerAffiliation,
        [int]$CommentSize = 0,
        [bool]$ForceCache = $false,
        [string]$Cursor = $null,
        [array]$Edges = @()
    )
    
    $script:QUERY_COUNT.loc_query++
    
    $query = @"
query (`$owner_affiliation: [RepositoryAffiliation], `$login: String!, `$cursor: String) {
    user(login: `$login) {
        repositories(first: 60, after: `$cursor, ownerAffiliations: `$owner_affiliation) {
            edges {
                node {
                    ... on Repository {
                        nameWithOwner
                        defaultBranchRef {
                            target {
                                ... on Commit {
                                    history {
                                        totalCount
                                    }
                                }
                            }
                        }
                    }
                }
            }
            pageInfo {
                endCursor
                hasNextPage
            }
        }
    }
}
"@
    
    $variables = @{
        owner_affiliation = $OwnerAffiliation
        login = $USER_NAME
        cursor = $Cursor
    }
    
    $result = Invoke-SimpleRequest -FuncName "Get-LocQuery" -Query $query -Variables $variables
    
    if ($result.data.user.repositories.pageInfo.hasNextPage) {
        $Edges += $result.data.user.repositories.edges
        return Get-LocQuery -OwnerAffiliation $OwnerAffiliation -CommentSize $CommentSize -ForceCache $ForceCache `
            -Cursor $result.data.user.repositories.pageInfo.endCursor -Edges $Edges
    }
    else {
        return New-CacheBuilder -Edges ($Edges + $result.data.user.repositories.edges) -CommentSize $CommentSize -ForceCache $ForceCache
    }
}

function New-CacheBuilder {
    param(
        [array]$Edges,
        [int]$CommentSize,
        [bool]$ForceCache
    )
    
    $cached = $true
    $hashString = Get-SHA256Hash -InputString $USER_NAME
    $filename = "cache/$hashString.txt"
    
    if (Test-Path $filename) {
        $data = Get-Content $filename
    }
    else {
        $data = @()
        if ($CommentSize -gt 0) {
            for ($i = 0; $i -lt $CommentSize; $i++) {
                $data += "This line is a comment block. Write whatever you want here."
            }
        }
        Set-Content -Path $filename -Value $data
    }
    
    if (($data.Count - $CommentSize) -ne $Edges.Count -or $ForceCache) {
        $cached = $false
        Clear-FlushCache -Edges $Edges -Filename $filename -CommentSize $CommentSize
        $data = Get-Content $filename
    }
    
    $cacheComment = if ($CommentSize -gt 0 -and $CommentSize -le $data.Count) { $data[0..($CommentSize - 1)] } else { @() }
    $data = if ($CommentSize -gt 0 -and $CommentSize -lt $data.Count) { $data[$CommentSize..($data.Count - 1)] } elseif ($CommentSize -ge $data.Count) { @() } else { $data }
    
    for ($index = 0; $index -lt $Edges.Count; $index++) {
        # Ensure cache data has enough entries
        if ($index -ge $data.Count) {
            Write-Warning "Cache file has fewer entries than expected. Rebuilding cache."
            Clear-FlushCache -Edges $Edges -Filename $filename -CommentSize $CommentSize
            $data = Get-Content $filename
            if ($CommentSize -gt 0 -and $CommentSize -lt $data.Count) { $data = $data[$CommentSize..($data.Count - 1)] }
            elseif ($CommentSize -ge $data.Count) { $data = @() }
        }
        
        $parts = $data[$index] -split '\s+'
        if ($parts.Count -lt 5) {
            Write-Warning "Invalid cache line at index $index. Skipping."
            continue
        }
        
        $repoHash = $parts[0]
        $commitCount = [int]$parts[1]
        
        $nodeHashString = Get-SHA256Hash -InputString $Edges[$index].node.nameWithOwner
        
        if ($repoHash -eq $nodeHashString) {
            try {
                if ($Edges[$index].node.defaultBranchRef -ne $null -and 
                    $commitCount -ne $Edges[$index].node.defaultBranchRef.target.history.totalCount) {
                    $ownerRepo = $Edges[$index].node.nameWithOwner -split '/'
                    $loc = Get-RecursiveLoc -Owner $ownerRepo[0] -RepoName $ownerRepo[1] -Data $data -CacheComment $cacheComment
                    $data[$index] = "$repoHash $($Edges[$index].node.defaultBranchRef.target.history.totalCount) $($loc[2]) $($loc[0]) $($loc[1])"
                }
            }
            catch {
                $data[$index] = "$repoHash 0 0 0 0"
            }
        }
    }
    
    $allLines = $cacheComment + $data
    Set-Content -Path $filename -Value $allLines
    
    $locAdd = 0
    $locDel = 0
    foreach ($line in $data) {
        $loc = $line -split '\s+'
        $locAdd += [int]$loc[3]
        $locDel += [int]$loc[4]
    }
    
    return @($locAdd, $locDel, ($locAdd - $locDel), $cached)
}

function Clear-FlushCache {
    param(
        [array]$Edges,
        [string]$Filename,
        [int]$CommentSize
    )
    
    $data = @()
    if (Test-Path $Filename) {
        $allData = Get-Content $Filename
        if ($CommentSize -gt 0 -and $allData.Count -ge $CommentSize) {
            $data = $allData[0..($CommentSize - 1)]
        }
    }
    
    foreach ($node in $Edges) {
        $hashString = Get-SHA256Hash -InputString $node.node.nameWithOwner
        $data += "$hashString 0 0 0 0"
    }
    
    Set-Content -Path $Filename -Value $data
}

function Add-Archive {
    $data = Get-Content "cache/repository_archive.txt"
    $oldData = $data
    
    # Validate array bounds before slicing
    if ($data.Count -lt 11) {
        Write-Warning "repository_archive.txt has insufficient data"
        return @(0, 0, 0, 0, 0)
    }
    
    $data = $data[7..($data.Count - 4)]
    
    $addedLoc = 0
    $deletedLoc = 0
    $addedCommits = 0
    $contributedRepos = $data.Count
    
    foreach ($line in $data) {
        $parts = $line -split '\s+'
        if ($parts.Count -lt 5) {
            Write-Warning "Invalid archive line format. Skipping."
            continue
        }
        $repoHash = $parts[0]
        $totalCommits = $parts[1]
        $myCommits = $parts[2]
        $addedLoc += [int]$parts[3]
        $deletedLoc += [int]$parts[4]
        if ($myCommits -match '^\d+$') {
            $addedCommits += [int]$myCommits
        }
    }
    
    $lastLineParts = $oldData[-1] -split '\s+'
    if ($lastLineParts.Count -lt 5) {
        Write-Warning "Invalid last line format in archive. Using 0 for additional commits."
        $lastValue = 0
    } else {
        $lastValue = $lastLineParts[4] -replace ',$', ''
    }
    $addedCommits += [int]$lastValue
    
    return @($addedLoc, $deletedLoc, ($addedLoc - $deletedLoc), $addedCommits, $contributedRepos)
}

function Save-ForceCloseFile {
    param(
        [array]$Data,
        [array]$CacheComment
    )
    
    $hashString = Get-SHA256Hash -InputString $USER_NAME
    $filename = "cache/$hashString.txt"
    
    $allLines = $CacheComment + $Data
    Set-Content -Path $filename -Value $allLines
    Write-Host "There was an error while writing to the cache file. The file, $filename, has had the partial data saved and closed."
}

function Get-StarsCounter {
    param(
        [array]$Data
    )
    
    $totalStars = 0
    foreach ($node in $Data) {
        $totalStars += $node.node.stargazers.totalCount
    }
    return $totalStars
}

function Update-SvgOverwrite {
    param(
        [string]$Filename,
        [string]$AgeData,
        [int]$CommitData,
        [int]$StarData,
        [int]$RepoData,
        [int]$ContribData,
        [int]$FollowerData,
        [array]$LocData
    )
    
    [xml]$svg = Get-Content $Filename
    
    Update-JustifyFormat -Root $svg -ElementId "commit_data" -NewText $CommitData -Length 22
    Update-JustifyFormat -Root $svg -ElementId "star_data" -NewText $StarData -Length 14
    Update-JustifyFormat -Root $svg -ElementId "repo_data" -NewText $RepoData -Length 6
    Update-JustifyFormat -Root $svg -ElementId "contrib_data" -NewText $ContribData
    Update-JustifyFormat -Root $svg -ElementId "follower_data" -NewText $FollowerData -Length 10
    Update-JustifyFormat -Root $svg -ElementId "loc_data" -NewText $LocData[2] -Length 9
    Update-JustifyFormat -Root $svg -ElementId "loc_add" -NewText $LocData[0]
    Update-JustifyFormat -Root $svg -ElementId "loc_del" -NewText $LocData[1] -Length 7
    
    $svg.Save((Resolve-Path $Filename).Path)
}

function Update-JustifyFormat {
    param(
        [xml]$Root,
        [string]$ElementId,
        $NewText,
        [int]$Length = 0
    )
    
    if ($NewText -is [int]) {
        $NewText = "{0:N0}" -f $NewText
    }
    $NewText = [string]$NewText
    
    Set-FindAndReplace -Root $Root -ElementId $ElementId -NewText $NewText
    
    $justLen = [Math]::Max(0, $Length - $NewText.Length)
    if ($justLen -le 2) {
        $dotString = @('', ' ', '. ')[$justLen]
    }
    else {
        $dotString = ' ' + ('.' * $justLen) + ' '
    }
    Set-FindAndReplace -Root $Root -ElementId "${ElementId}_dots" -NewText $dotString
}

function Set-FindAndReplace {
    param(
        [xml]$Root,
        [string]$ElementId,
        [string]$NewText
    )
    
    $namespaceManager = New-Object System.Xml.XmlNamespaceManager($Root.NameTable)
    $namespaceManager.AddNamespace("svg", "http://www.w3.org/2000/svg")
    
    $element = $Root.SelectSingleNode("//*[@id='$ElementId']", $namespaceManager)
    if ($element -eq $null) {
        $element = $Root.SelectSingleNode("//*[@id='$ElementId']")
    }
    
    if ($element -ne $null) {
        $element.InnerText = $NewText
    }
}

function Get-CommitCounter {
    param(
        [int]$CommentSize
    )
    
    $totalCommits = 0
    $hashString = Get-SHA256Hash -InputString $USER_NAME
    $filename = "cache/$hashString.txt"
    
    $data = Get-Content $filename
    $data = if ($CommentSize -gt 0 -and $CommentSize -lt $data.Count) { $data[$CommentSize..($data.Count - 1)] } elseif ($CommentSize -ge $data.Count) { @() } else { $data }
    
    foreach ($line in $data) {
        $parts = $line -split '\s+'
        if ($parts.Count -lt 3) {
            Write-Warning "Invalid cache line format. Skipping."
            continue
        }
        $totalCommits += [int]$parts[2]
    }
    
    return $totalCommits
}

function Get-UserGetter {
    param(
        [string]$Username
    )
    
    $script:QUERY_COUNT.user_getter++
    
    $query = @"
query(`$login: String!) {
    user(login: `$login) {
        id
        createdAt
    }
}
"@
    
    $variables = @{ login = $Username }
    $result = Invoke-SimpleRequest -FuncName "Get-UserGetter" -Query $query -Variables $variables
    
    return @{ id = $result.data.user.id }, $result.data.user.createdAt
}

function Get-FollowerGetter {
    param(
        [string]$Username
    )
    
    $script:QUERY_COUNT.follower_getter++
    
    $query = @"
query(`$login: String!) {
    user(login: `$login) {
        followers {
            totalCount
        }
    }
}
"@
    
    $variables = @{ login = $Username }
    $result = Invoke-SimpleRequest -FuncName "Get-FollowerGetter" -Query $query -Variables $variables
    
    return [int]$result.data.user.followers.totalCount
}

function Measure-PerfCounter {
    param(
        [scriptblock]$ScriptBlock,
        [array]$Arguments = @()
    )
    
    $start = Get-Date
    $result = & $ScriptBlock @Arguments
    $end = Get-Date
    $difference = ($end - $start).TotalSeconds
    
    return @($result, $difference)
}

function Write-Formatter {
    param(
        [string]$QueryType,
        [double]$Difference,
        $FunctReturn = $false,
        [int]$Whitespace = 0
    )
    
    $queryFormatted = "   $QueryType`:".PadRight(23)
    Write-Host -NoNewline $queryFormatted
    
    if ($Difference -gt 1) {
        Write-Host ("{0,12}" -f ("{0:N4} s" -f $Difference))
    }
    else {
        Write-Host ("{0,12}" -f ("{0:N4} ms" -f ($Difference * 1000)))
    }
    
    if ($Whitespace) {
        return ("{0:N0}" -f $FunctReturn).PadLeft($Whitespace)
    }
    return $FunctReturn
}

# Main script execution
Write-Host "Calculation times:"

# Get user data
$userData = Measure-PerfCounter -ScriptBlock { Get-UserGetter -Username $USER_NAME }
$script:OWNER_ID = $userData[0][0]
$accDate = $userData[0][1]
Write-Formatter -QueryType "account data" -Difference $userData[1]

# Calculate age
$ageData = Measure-PerfCounter -ScriptBlock { Get-DailyReadme -Birthday ([DateTime]::new(2002, 7, 5)) }
Write-Formatter -QueryType "age calculation" -Difference $ageData[1]

# Get LOC data
$totalLoc = Measure-PerfCounter -ScriptBlock { Get-LocQuery -OwnerAffiliation @('OWNER', 'COLLABORATOR', 'ORGANIZATION_MEMBER') -CommentSize 7 }
if ($totalLoc[0][3]) {
    Write-Formatter -QueryType "LOC (cached)" -Difference $totalLoc[1]
}
else {
    Write-Formatter -QueryType "LOC (no cache)" -Difference $totalLoc[1]
}

# Get commit data
$commitData = Measure-PerfCounter -ScriptBlock { Get-CommitCounter -CommentSize 7 }

# Get star data
$starData = Measure-PerfCounter -ScriptBlock { Get-GraphReposStars -CountType "stars" -OwnerAffiliation @('OWNER') }

# Get repo data
$repoData = Measure-PerfCounter -ScriptBlock { Get-GraphReposStars -CountType "repos" -OwnerAffiliation @('OWNER') }

# Get contrib data
$contribData = Measure-PerfCounter -ScriptBlock { Get-GraphReposStars -CountType "repos" -OwnerAffiliation @('OWNER', 'COLLABORATOR', 'ORGANIZATION_MEMBER') }

# Get follower data
$followerData = Measure-PerfCounter -ScriptBlock { Get-FollowerGetter -Username $USER_NAME }

# Add archived data if this is the specific user
if ($script:OWNER_ID.id -eq 'MDQ6VXNlcjU3MzMxMTM0') {
    $archivedData = Add-Archive
    for ($i = 0; $i -lt ($totalLoc[0].Count - 1); $i++) {
        $totalLoc[0][$i] += $archivedData[$i]
    }
    $contribData[0] += $archivedData[-1]
    $commitData[0] += [int]$archivedData[-2]
}

# Format LOC data
for ($i = 0; $i -lt ($totalLoc[0].Count - 1); $i++) {
    $totalLoc[0][$i] = "{0:N0}" -f $totalLoc[0][$i]
}

# Update SVG files
Update-SvgOverwrite -Filename "dark_mode.svg" -AgeData $ageData[0] -CommitData $commitData[0] `
    -StarData $starData[0] -RepoData $repoData[0] -ContribData $contribData[0] `
    -FollowerData $followerData[0] -LocData $totalLoc[0][0..($totalLoc[0].Count - 2)]

Update-SvgOverwrite -Filename "light_mode.svg" -AgeData $ageData[0] -CommitData $commitData[0] `
    -StarData $starData[0] -RepoData $repoData[0] -ContribData $contribData[0] `
    -FollowerData $followerData[0] -LocData $totalLoc[0][0..($totalLoc[0].Count - 2)]

# Calculate total time
$totalTime = $userData[1] + $ageData[1] + $totalLoc[1] + $commitData[1] + $starData[1] + $repoData[1] + $contribData[1] + $followerData[1]

# Print summary
Write-Host ""
Write-Host ("Total function time:".PadRight(21) + ("{0,11} s" -f ("{0:N4}" -f $totalTime)))
Write-Host ""
Write-Host "Total GitHub GraphQL API calls:" ("{0,3}" -f ($QUERY_COUNT.Values | Measure-Object -Sum).Sum)
foreach ($key in $QUERY_COUNT.Keys) {
    Write-Host ("   $key`:".PadRight(28) + ("{0,6}" -f $QUERY_COUNT[$key]))
}
