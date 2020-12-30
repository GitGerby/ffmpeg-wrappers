[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [ValidateScript({Test-Path -LiteralPath $_ -PathType Leaf})]
    [String]
    $InputFile,
    [String]
    $OutputFile = "$($InputFile)_output.mkv",
    [ValidateSet('libx265','nvenc')]
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
    $ToneMapMethod = 'hable'
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
  '-rc_lookahead', '48',
  '-preset', $nvpreset
)

if ($(& ffmpeg *>&1) -notmatch 'opencl' -and -not $DisableOpenCL) {
  throw 'ffmpeg was not compiled with OpenCL support and OpenCL was not disabled at runtime'
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

  & ffmpeg @cropdetectargs *>&1 | 
    Foreach-Object {
      $_ -match '(crop=[-\d:]*)' | Out-Null
    }
  $crop = $matches[1]
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
    '-init_hw_device', "opencl=gpu$GpuIndex",
    '-filter_hw_device', 'gpu'
  )
}

# Set decoder
if (!$DisableHardwareDecode) {
  $encodeargs += @(
    '-hwaccel', 'auto', 
    '-hwaccel_output_format', 'p010'
  )
}

# Input file and specify that all streams should be mapped across to output
$encodeargs += @(
  '-i', $InputFile,
  '-map','0'
)

# Construct filter graph
$opencltonemap = "hwupload,tonemap_opencl=t=bt2020:tonemap=$ToneMapMethod:format=p010,hwdownload,format=p010"
$softwaretonemap = "zscale=linear,tonemap=$ToneMapMethod,zscale=transfer=bt709"

$filters = ""
if ($DisableOpenCL) {
  $filters += $softwaretonemap
} else {
  $filters += $opencltonemap
}

if (-not $DoNotCrop) {
  $filters += ",$crop"
}

switch ($Encoder) {
  'nvenc' {$filters += ',hwupload_cuda'}
}

# Add filter to encoding args
$encodeargs += @(
  '-vf', $filters
)

switch ($Encoder) {
  'nvenc' {$encodeargs += $NVENCARGS}
  'libx265' {$encodeargs += $LIBX265ARGS}
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
& ffmpeg @encodeargs