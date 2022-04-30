[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [ValidateScript({Test-Path -LiteralPath $_ -PathType Leaf})]
    [String]
    $InputFile,
    [String]
    $OutputFile = "$($InputFile)_output.mkv",
    [ValidateSet('libx265','nvenc', 'qsv','vce')]
    [String]
    $Encoder = 'nvenc',
    [int]
    $Crf = 18,
    [ValidateSet('grain','animation')]
    [String]
    $Tune = '',
    [ValidateSet('ultrafast','superfast','veryfast','faster','fast','medium','slow','slower','veryslow')]
    $Preset = 'medium',
    [int]
    $CropScan = 300,
    [Switch]
    $DisableHardwareDecode,
    [Switch]
    $DoNotCrop,
    [Switch]
    $DisableOpenCL,
    [String]
    $GpuIndex = '0.0',
    [ValidateSet('none','clip','linear','gamma','reinhard','hable','mobius')]
    [string]
    $ToneMapMethod = 'hable',
    [switch]
    $ScaleTo1080
)

# Define Constants for encoder arguments
$LIBX265ARGS = @(
  '-c:v', 'libx265',
  '-crf', $crf,
  '-preset', $Preset
)
if ($Tune -ne ''){
  $LIBX265ARGS += @('-tune', $Tune)
}

switch -wildcard ($Preset) {
  '*fast*' { $nvpreset = 3 }
  'medium' { $nvpreset = 2 }
  '*slow*' { $nvpreset = 1 }
  Default { $nvpreset = 2 }
}

$NVENCARGS = @(
  '-c:v', 'hevc_nvenc',
  '-rc', 'vbr',
  '-cq', $Crf,
  '-profile:v', '1',
  '-tier', '1',
  '-spatial_aq', '1',
  '-temporal_aq', '1',
  '-preset', $nvpreset
)

switch ($Preset){
  'veryfast' { $qsvpreset = 7 }
  'faster' { $qsvpreset = 6 }
  'fast' { $qsvpreset = 5 }
  'medium' { $qsvpreset = 4 }
  'slow' { $qsvpreset = 3 }
  'slower' { $qsvpreset = 2 }
  'veryslow' { $qsvpreset = 1 }
  Default { $qsvpreset = 4 }
}

$QSVARGS = @(
  '-c:v', 'hevc_qsv',
  '-adaptive_i', '1',
  '-adaptive_b', '1',
  '-global_quality', $Crf,
  '-preset', $qsvpreset,
  '-look_ahead', '48'
)

$AMFARGS = @(
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

# Locate ffmpeg
if (Test-Path "$PSScriptRoot\ffmpeg.exe") {
  $ffmpegbinary = "$PSScriptRoot\ffmpeg.exe"
} elseif (Get-Command 'ffmpeg') {
  $ffmpegbinary = $(Get-Command 'ffmpeg').Source
} else {
  throw "Could not locate ffmpeg in $PSScriptRoot or PATH"
}

Write-Host "Using ffmpeg binary at: $ffmpegbinary"

$openclsupport = $false
& $ffmpegbinary *>&1 | ForEach-Object {
  if ($_ -match 'opencl') {
    $script:openclsupport = $true
  }
}

if (-not $openclsupport) {
  Write-Host 'ffmpeg binary does not support opencl, disabling opencl processing.'
  $DisableOpenCL = $true
}

if (-not $DoNotCrop){
  Write-Host "Scanning the first $CropScan seconds to determine proper crop settings."
  $cropdetectargs = @('-hide_banner')
  if (!$DisableHardwareDecode) {
    $cropdetectargs += @('-hwaccel', 'auto')
  }
  $cropdetectargs += @(
    '-analyzeduration', '6000M',
    '-probesize', '6000M'
    '-i', "$InputFile", 
    '-t', $CropScan, 
    '-vf', 'cropdetect=round=2',
    '-max_muxing_queue_size', '4096', 
    '-f', 'null', 'NUL')

  & $ffmpegbinary @cropdetectargs *>&1 | 
    Foreach-Object {
      $_ -match 't:([\d]*).*?(crop=[-\d:]*)' | Out-Null
      if ($matches[1] -ge 0) {
        Write-Progress -Activity 'Detecting crop settings' -Status "t=$($matches[1]) $($matches[2])" -PercentComplete $($([int]$matches[1] / $CropScan)*100)
      }
    }
  $crop = $matches[2]
  Write-Host "Using $crop"
}

# Begin flag construction
$encodeargs = @(
  '-hide_banner',
  '-analyzeduration', '6000M',
  '-probesize', '6000M'
)

# Init hw device for OpenCL
if (-not $DisableOpenCL) {
  $encodeargs += @(
    '-init_hw_device', "opencl=gpu:$GpuIndex",
    '-filter_hw_device', 'gpu'
  )
}

# Set decoder
# Disable hardware decoding when using VCE
if ($Encoder -eq 'vce') {
  $DisableHardwareDecode = $true
}
if (-not $DisableHardwareDecode) {
  switch($Encoder) {
    'nvenc' {
      $encodeargs += @(
        '-hwaccel', 'nvdec',
        '-hwaccel_output_format', 'p010'
      )
    }
    'qsv' {
      $encodeargs += @(
        '-hwaccel', 'qsv',
        '-hwaccel_output_format', 'qsv'
      )
    }
    Default {
      $encodeargs += @(
        '-hwaccel', 'auto',
        '-hwaccel_output_format', 'p010'
       )
    }
  }
}

# Input file and specify that all streams should be mapped across to output
$encodeargs += @(
  '-i', $InputFile,
  '-map','0'
)

# Construct filter graph
$filters = '[0:v:0]'

if($DisableHardwareDecode) {
  $filters += 'format=p010,'
}

if (-not $DoNotCrop) {
  $filters += "$crop,"
}

switch ($Encoder) {
  'qsv' { $filters += 'format=p010,' }
  'vce' { $filters += 'format=p010,' }
}

$opencltonemap = "hwupload,tonemap_opencl=t=bt2020:tonemap=$ToneMapMethod"+':format=p010,hwdownload,format=p010'
$softwaretonemap = "zscale=linear,tonemap=$ToneMapMethod,zscale=transfer=bt709"

if ($DisableOpenCL) {
  $filters += $softwaretonemap
} else {
  $filters += $opencltonemap
}

if ($ScaleTo1080) {
  switch ($Encoder){
   'nvenc' { $filters += ',hwupload_cuda,scale_cuda=w=1920:h=1080:interp_algo=lanczos:force_original_aspect_ratio=decrease' }
   Default { $filters += ',zscale=w=1920:h=1080:force_original_aspect_ratio=decrease' }
  }
}

if (-not $ScaleTo1080) {
  switch ($Encoder) {
    'nvenc' {$filters += ',hwupload_cuda'}
  }
}

# Add filter to encoding args
$encodeargs += @(
  '-filter_complex', $filters
)

switch ($Encoder) {
  'nvenc' { $encodeargs += $NVENCARGS }
  'libx265' { $encodeargs += $LIBX265ARGS }
  'qsv' { $encodeargs += $QSVARGS }
  'vce' { $encodeargs += $AMFARGS }
}

# Copy audio and subtitle streams, ensure sufficient muxer space
$encodeargs += @(
  '-c:a', 'copy',
  '-c:s', 'copy',
  '-max_muxing_queue_size', '4096'
)

# Specify destination
$encodeargs += @($OutputFile)
Write-Host "Calling ffmpeg with: $($encodeargs -join ' ')"
& $ffmpegbinary @encodeargs