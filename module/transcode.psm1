$script:REGISTRYKEY = 'HKCU:\SOFTWARE\ffmpeg-wrappers'
$script:COMMONPARAMS = @(
  '-probesize', '6000M',
  '-analyzeduration', '6000M'
)

function Get-Crop {
  [CmdletBinding()]
  param (
    [string]$Source,
    [string]$FfmpegPath
  )

  if (-not $FfmpegPath) {
    try {
      $FfmpegPath = Get_FfmpegPath
    }
    catch {
      Set-FfmpegPath
      $FfmpegPath = Get_FfmpegPath
    }
    Write-Verbose "Using ffmpeg at: $FfmpegPath"
  }

  Write-Verbose "Automatically detecting crop settings for $Source"
  & $FfmpegPath @script:COMMONPARAMS -i $Source -vf 'cropdetect=round=2' -t 180 -f null NUL *>&1 | 
  ForEach-Object {
    $_ -match 't:([\d]*).*?(crop=[-\d:]*)' | Out-Null
  }
  Write-Verbose "Setting crop filter to: $($matches[2])"
  return $matches[2]
}

function Start-Transcode {
  [CmdletBinding()]
  param (
    [string]$Source,
    [string]$Destination,
    [string]$Crop,
    [int]$Crf = 18,
    [string]$Filters,
    [switch]$NoCrop,
    [string]$Language = 'eng',
    [string]$FfmpegPath,
    [switch]$Overwrite
  )

  $NVENCARGS = @(
    '-c:v', 'hevc_nvenc',
    '-rc', '1',
    '-cq', $Crf,
    '-profile:v', '1',
    '-tier', '1',
    '-spatial_aq', '1',
    '-temporal_aq', '1',
    '-preset', '1',
    '-b_ref_mode', '2'
  )

  # Find the binary to call
  if (-not $FfmpegPath) {
    try {
      $FfmpegPath = Get_FfmpegPath
    }
    catch {
      Set-FfmpegPath
      $FfmpegPath = Get_FfmpegPath
    }
    Write-Verbose "Using ffmpeg at: $FfmpegPath"
  }

  # Begin building arglist
  $ffmpegargs = @()
  if ($Overwrite) {
    $ffmpegargs += @('-y')
  }
  $ffmpegargs += $COMMONPARAMS
  if (-not $PSCmdlet.MyInvocation.BoundParameters["Verbose"].IsPresent) { 
    $ffmpegargs += @('-hide_banner', '-loglevel', 'error', '-stats')
  }
  
  # Add input file to args and filter on language.
  $inputargs = @()
  $inputargs += @('-i', $Source)
  $mapargs = @('-map', "0:m:language:$Language")

  # Find sidecar SRT files to insert into destination file
  $resolvedinput = Get-Item -LiteralPath $Source
  $srts = Get-ChildItem -LiteralPath $resolvedinput.Directory.FullName -Filter '*.srt' | Where-Object FullName -match $($($resolvedinput.name -split '\.')[0]) | Sort-Object -Descending
  $i = 1
  foreach ($srt in $srts) {
    $inputargs += @('-i', $srt.FullName)
    $mapargs += @('-map', "$i", '-metadata:s:s', 'language=eng')
    $i++
  }
  Write-Verbose "Resolved input args to $inputargs"
  
  # Add discovered subtitles to args
  $ffmpegargs += $inputargs 

  # build simple filter chain
  if ((-not $NoCrop) -and (-not $Crop)) {
    $Crop = Get-Crop -Source $Source -FfmpegPath $FfmpegPath
  }

  $filterstring = @('-vf', $Crop)
  if ($Filters.Trim() -ne '') {
    $filterstring = $Crop + ';' + $Filters
  }
  Write-Verbose "Built simple video filter: $filterstring"
  $ffmpegargs += $filterstring

  # add encoder, mapping, and output args
  $ffmpegargs += $NVENCARGS + @('-c:a', 'copy', '-c:s', 'copy') + $mapargs + @($Destination)

  Write-Verbose "Final argument list: $($ffmpegargs -join ', ')"

  & $FfmpegPath @ffmpegargs
}

function Get_FfmpegPath {
  [CmdletBinding()]
  param(
  )
  
  Write-Verbose 'Searching for ffmpeg binary.'

  if ($env:FFMPEG) {
    return $env:FFMPEG
  }

  $reg = (Get-ItemProperty $script:REGISTRYKEY -Name 'ffmpeg_binary' -ErrorAction SilentlyContinue).ffmpeg_binary
  if ($reg) {
    return $reg
  }

  $checkpath = (Get-Command 'ffmpeg.exe').Source
  if ($checkpath) {
    return $checkpath
  }

  $workinglocation = (Get-ChildItem $(Get-Location) -Filter 'ffmpeg.exe' -File).FullName
  if ($workinglocation) {
    return $workinglocation
  }

  $scriptlocation = (Get-ChildItem $PSScriptRoot -Filter 'ffmpeg.exe' -File).FullName
  if ($scriptlocation) {
    return $scriptlocation
  }
  
  Write-Error 'Cannot locate ffmpeg.exe'
}

function Set-FfmpegPath {
  [CmdletBinding()]
  param (
    [string]$Path
  )

  if (-not $(Test-Path $script:REGISTRYKEY)) {
    New-Item $script:REGISTRYKEY -Force
  }

  if ($Path) {
    New-ItemProperty -Path $script:REGISTRYKEY -Name 'ffmpeg_binary' -Value $Path -Force
  }
  else {
    New-ItemProperty -Path $script:REGISTRYKEY -Name 'ffmpeg_binary' -Value $(Read-Host -Prompt 'Path to ffmpeg.exe: ') -Force
  }
}