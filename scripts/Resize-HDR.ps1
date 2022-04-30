[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [ValidateScript({Test-Path -LiteralPath $_ -PathType Leaf})]
    [String]
    $InputFile,
    [String]
    $OutputFile = "$($InputFile)_output.mkv",
    # At this time only libx265 supports setting the appropriate colorspace flags for HDR content.
    [ValidateSet('libx265')]
    [String]
    $Encoder = 'libx265',
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
    $DisableHardwareDecode
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

# Locate ffmpeg
if (Test-Path "$PSScriptRoot\ffmpeg.exe") {
  $ffmpegbinary = "$PSScriptRoot\ffmpeg.exe"
} elseif (Get-Command 'ffmpeg') {
  $ffmpegbinary = $(Get-Command 'ffmpeg').Source
} else {
  throw "Could not locate ffmpeg in $PSScriptRoot or PATH"
}

# Locate ffprobe
if (Test-Path "$PSScriptRoot\ffprobe.exe") {
  $ffprobebinary = "$PSScriptRoot\ffprobe.exe"
} elseif (Get-Command 'ffprobe') {
  $ffprobebinary = $(Get-Command 'ffprobe').Source
} else {
  throw "Could not locate ffprobe in $PSScriptRoot or PATH"
}

# Scan the first N seconds of the file to detect what can be cropped
Write-Host "Scanning the first $CropScan seconds to determine proper crop settings."
$cropdetectargs = @('-hide_banner')
if (-not $DisableHardwareDecode) {
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

# Extract and normalize color settings
Write-Host 'Detecting color space and HDR parameters'
$ffprobeargs = @(
  '-hide_banner',
  '-loglevel', 'warning'
  '-select_stream', 'v'
  '-analyzeduration', '6000M',
  '-probesize', '6000M',
  '-print_format', 'json',
  '-show_frames',
  '-read_intervals', "%+#1",
  '-show_entries', 'frame=color_space,color_primaries,color_transfer,side_data_list,pix_fmt',
  '-i', $InputFile
)
$rawprobe = & $ffprobebinary @ffprobeargs
$hdrmeta = ($rawprobe | ConvertFrom-Json).Frames

$colordata = @{}
$colordata['red_x'] = [int]$($hdrmeta.side_data_list.red_x -split '/')[0] * (50000 / ($($hdrmeta.side_data_list.red_x -split '/')[1]))
$colordata['red_y'] = [int]$($hdrmeta.side_data_list.red_y -split '/')[0] * (50000 / ($($hdrmeta.side_data_list.red_y -split '/')[1]))
$colordata['green_x'] = [int]$($hdrmeta.side_data_list.green_x -split '/')[0] * (50000 / ($($hdrmeta.side_data_list.green_x -split '/')[1]))
$colordata['green_y'] = [int]$($hdrmeta.side_data_list.green_y -split '/')[0] * (50000 / ($($hdrmeta.side_data_list.green_y -split '/')[1]))
$colordata['blue_x'] = [int]$($hdrmeta.side_data_list.blue_x -split '/')[0] * (50000 / ($($hdrmeta.side_data_list.blue_x -split '/')[1]))
$colordata['blue_y'] = [int]$($hdrmeta.side_data_list.blue_y -split '/')[0] * (50000 / ($($hdrmeta.side_data_list.blue_y -split '/')[1]))
$colordata['white_point_x'] = [int]$($hdrmeta.side_data_list.white_point_x -split '/')[0] * (50000 / ($($hdrmeta.side_data_list.white_point_x -split '/')[1]))
$colordata['white_point_y'] = [int]$($hdrmeta.side_data_list.white_point_y -split '/')[0] * (50000 / ($($hdrmeta.side_data_list.white_point_y -split '/')[1]))

$colordata['max_luminance'] = [int]($($hdrmeta.side_data_list.max_luminance -split '/')[0] * (10000 / ($($hdrmeta.side_data_list.max_luminance -split '/')[1])))
$colordata['min_luminance'] = [int]($($hdrmeta.side_data_list.min_luminance -split '/')[0] * (10000 / ($($hdrmeta.side_data_list.min_luminance -split '/')[1])))

$contentlightlevel = @{
  'max_content' = [int]$hdrmeta.side_data_list.max_content;
  'max_avg' = [int]$hdrmeta.side_data_list.max_average;
} 

$encodeargs = @(
  '-hide_banner',
  '-analyzeduration', '6000M',
  '-probesize', '6000M'
)
# Set decoder
if (!$DisableHardwareDecode) {
  $encodeargs += @('-hwaccel', 'auto')
}

$encodeargs += @(
  '-i', $InputFile,
  '-map','0'
)
# Set encoder
switch ($Encoder) {
  'libx265' {$encodeargs += $LIBX265ARGS}
}

# Add filters
$encodeargs += @(
  '-vf', $crop
)

# Add HDR flags
$hdrparams = 'hdr-opt=1:repeat-headers=1:colorprim=' + $hdrmeta.color_primaries + 
  ':transfer=' + $hdrmeta.color_transfer + 
  ':colormatrix=' + $hdrmeta.color_space + 
  ':master-display='+ "G($($colordata.green_x),$($colordata.green_y))" +
  "B($($colordata.blue_x),$($colordata.blue_y))" + 
  "R($($colordata.red_x),$($colordata.red_y))" +
  "WP($($colordata.white_point_x),$($colordata.white_point_y))" + 
  "L($($colordata.max_luminance),$($colordata.min_luminance))" +
  ":max-cll=$($contentlightlevel['max_content']),$($contentlightlevel['max_avg'])"

$encodeargs += @(
  '-x265-params', $hdrparams
)

# Copy audio and subtitle streams
$encodeargs += @(
  '-c:a', 'copy',
  '-c:s', 'copy'
)

# Ensure we have a sufficient muxing queue
$encodeargs += @(
  '-max_muxing_queue_size', '4096',
  '-pix_fmt', 'yuv420p10le'
)

# Specify destination
$encodeargs += @($OutputFile)
Write-Host "Calling ffmpeg with: $($encodeargs -join ' ')"
& $ffmpegbinary @encodeargs