# Copyright 2022 GearnsC
# 
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#     http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

$script:REGISTRYKEY = 'HKCU:\SOFTWARE\ffmpeg-wrappers'
$script:COMMONPARAMS = @(
  '-probesize', '6000M',
  '-analyzeduration', '6000M'
)

function Get-Crop {
  [CmdletBinding()]
  param (
    [ValidateNotNullOrEmpty()]
    [string]$Source,
    [string]$FfmpegPath,
    [switch]$HwDecode
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
  $params = $script:COMMONPARAMS
  if ($HwDecode) {
    $params += @('-hwaccel', 'auto')
  }


  Write-Verbose "Automatically detecting crop settings for $Source"
  & $FfmpegPath @params -i $Source -vf 'cropdetect=round=2' -t 180 -f null NUL *>&1 | 
  ForEach-Object {
    if ($_ -match 't:([\d]*).*?(crop=[-\d:]*)') {
      # Write a progress bar during crop detection if -Verbose is specified
      if (([int]$matches[1] -gt 0) -and ($([int]$matches[1] % 30) -eq 0 ) -and $PSCmdlet.MyInvocation.BoundParameters["Verbose"].IsPresent) {
        Write-Progress -Activity 'Crop detection' -Status "Time $($matches[1]) Filter: $($matches[2])" -PercentComplete $($([int]$matches[1] / 180) * 100)
      }
    }
  }
  Write-Verbose "Setting crop filter to: $($matches[2])"
  return $matches[2]
}

function Start-Transcode {
  [CmdletBinding()]
  param (
    [Parameter(ValueFromPipelineByPropertyName)]
    [ValidateNotNullOrEmpty()]
    [string]$Source,
    [Parameter(ValueFromPipelineByPropertyName)]
    [ValidateNotNullOrEmpty()]
    [string]$Destination,
    [string]$Crop,
    [int]$Crf = 18,
    [string]$Filters,
    [switch]$NoCrop,
    [string]$Language = 'eng',
    [string]$FfmpegPath,
    [switch]$Overwrite,
    [ValidateSet('auto', 'copy', 'nvenc', 'vcn', 'qsv', 'libx265')]
    [string]$Encoder = 'auto',
    [switch]$HwDecode
  )
  BEGIN {
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

    if ($Encoder -eq 'auto') {
      $Encoder = Get_VideoEncoder
      Write-Verbose "Autodetection resulted in: $Encoder"
    }

    # Begin building arglist
    $beginargs = @()  
    if ($Overwrite) {
      $beginargs += @('-y')
    }
    $beginargs += $script:COMMONPARAMS
    $pipeoutput = @()
  }

  PROCESS {
    $ffmpegargs = $beginargs

    # If -Verbose wasn't specified then add args to make ffmpeg quieter
    if (-not $PSCmdlet.MyInvocation.BoundParameters["Verbose"].IsPresent) { 
      $ffmpegargs += @('-hide_banner', '-loglevel', 'error', '-stats')
    }

    if ($HwDecode) {
      $ffmpegargs += @('-hwaccel', 'auto')
    }
    
    # Add input file to args and filter on language.
    $inputargs = @()
    $inputargs += @('-i', $Source)
    $mapargs = @('-map', "0:m:language:$($Language)?", '-map', '0:v:0')

    # Find sidecar SRT files to insert into destination file
    $resolvedinput = Get-Item -LiteralPath $Source
    $srts = Get-ChildItem -LiteralPath $resolvedinput.Directory.FullName -Filter '*.srt' | Where-Object FullName -match $($($resolvedinput.name -split '\.')[0]) | Sort-Object -Descending
    $i = 1
    foreach ($srt in $srts) {
      $inputargs += @('-i', $srt.FullName)
      $mapargs += @('-map', "$i", '-metadata:s:s', "language=$Language")
      $i++
    }
    Write-Verbose "Resolved input args to $inputargs"
    
    # Add discovered subtitles to args
    $ffmpegargs += $inputargs 

    # build simple filter chain
    if ((-not $NoCrop) -and (-not $Crop)) {
      $Crop = Get-Crop -Source $Source -FfmpegPath $FfmpegPath -HwDecode:$HwDecode
    }
    
    $filterstring = @('-vf', $Crop)
    if ($Filters.Trim() -ne '') {
      $filterstring[1] = $Crop + ';' + $Filters
    }
    if ($filterstring[1].Trim()) {
      Write-Verbose "Built simple video filter: $filterstring"
      $ffmpegargs += $filterstring
    }
    
    # add encoder args
    switch -exact ($Encoder) {
      'nvenc' {
        $ffmpegargs += @(
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
      }
      'copy' {
        '-c:v', 'copy'
      }
      'vcn' {
        $ffmpegargs += @(
          '-c:v', 'hevc_amf',
          '-rc', '2',
          '-quality', '0',
          '-vbaq', '1',
          '-preanalysis', '1',
          '-profile:v', '1',
          '-profile_tier', '1',
          '-level', '186',
          '-min_qp_i', '0',
          '-max_qp_i', '9',
          '-min_qp_p', '0',
          '-max_qp_p', $($Crf + 6),
          '-usage', '0'
        )
      }
      'qsv' {
        $ffmpegargs += @(
          '-c:v', 'hevc_qsv',
          '-adaptive_i', '1',
          '-adaptive_b', '1',
          '-global_quality', $Crf,
          '-preset', '3',
          '-look_ahead', '48'
        )
      }
      default {
        $ffmpegargs += @(
          '-c:v', 'libx265',
          '-crf', $crf,
          '-preset', 'medium'
          '-profile:v', 'main10'
        )
      }
    }


    # add mapping, and output args
    $ffmpegargs += @('-c:a', 'copy', '-c:s', 'copy') + $mapargs + @($Destination)

    Write-Verbose "Final argument list: $($ffmpegargs -join ', ')"

    & $FfmpegPath @ffmpegargs

    $pipeoutput += Get-Item -LiteralPath $Destination
  }
  
  END {
    $pipeoutput
  }
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

  $checkpath = (Get-Command 'ffmpeg.exe' -ErrorAction SilentlyContinue).Source
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
  
  throw 'Cannot locate ffmpeg.exe'
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

function Get_VideoEncoder {
  switch -Regex ((Get-CimInstance Win32_VideoController).Name ) {
    'nvidia' {$n = $true}
    'intel'  {$i = $true}
    'amd'    {$a = $true}
  }
  if ($n) {
    return 'nvenc'
  }
  if ($i) {
    return 'qsv'
  }
  if ($a) {
    return 'vcn'
  }
  return 'libx265'
}

function Get-VideoCodec {
  [CmdletBinding()]
  param (
    [string] $Path
  )
  ffprobe -v error -select_streams v:0 -probesize 6000M -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 $Source.FullName
}