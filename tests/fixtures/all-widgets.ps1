<#
.SYNOPSIS
Fixture: exercises every parameter widget shape Hub's autodetect supports.
.PARAMETER Name
Friendly display name (comment-help fallback path).
.PARAMETER Count
How many times to repeat.
.PARAMETER Slug
Lowercase slug used in URLs.
#>
param(
    [string]$Name,
    [int]$Count,
    [double]$Ratio,
    [decimal]$Price,
    [bool]$Enabled,
    [switch]$Force,
    [datetime]$When,
    [guid]$Id,
    [uri]$Target,
    [securestring]$Pin,
    [string[]]$Tags,
    [hashtable]$Map,
    [System.IO.FileInfo]$InputFile,
    [ValidateSet('a','b','c')]
    [string]$Mode,
    [ValidateRange(1,99)]
    [int]$Retries,
    [ValidatePattern('^[a-z]+$')]
    [string]$Slug,
    [ValidateLength(3,20)]
    [string]$Code,
    [ValidateNotNullOrEmpty()]
    [string]$NonEmpty,
    [Alias('Out','Output')]
    [string]$Destination,
    [Parameter(Mandatory, HelpMessage='hm')]
    [string]$Required,
    [Parameter(ParameterSetName='SetA', Position=0)]
    [string]$AlphaOnly,
    [Parameter(ParameterSetName='SetB', Position=0)]
    [string]$BetaOnly
)
Write-Output 'ok'
