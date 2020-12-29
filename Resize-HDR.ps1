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
    $Crf = 17,
    [ValidateSet('grain','animation')]
    [String]
    $tune = '',
    [ValidateSet('ultrafast','superfast','veryfast','faster','fast','medium','slow','slower','veryslow')]
    $preset = 'medium',
    [int]
    $CropScan = 120,
    [Switch]
    $DisableHardwareDecode
)

# Define Constants for encoder arguments
$LIBX265ARGS = @(
  '-c:v', 'libx265',
  '-crf', $crf,
  '-preset', $preset
)
if ($tune -ne ''){
  $LIBX265ARGS += @('-tune', $tune)
}

# Scan the first N seconds of the file to detect what can be cropped
Write-Host 'Scanning the first n seconds to determine proper crop settings.'
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

# Extract and normalize color settings
Write-Host 'Detecting color space and HDR parameters'
$rawprobe = & ffprobe -hide_banner -loglevel warning -select_streams v -print_format json -show_frames -read_intervals "%+#1" -show_entries "frame=color_space,color_primaries,color_transfer,side_data_list,pix_fmt" -i "$InputFile"
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


$encodeargs = @(
  '-hide_banner',
  '-analyzeduration', '6000M',
  '-probesize', '6000M'
)
# Set decoder
if (!$DisableHardwareDecode) {
  $encodeargs += @('-hwaccel', 'auto')
}

# Set input
$encodeargs += @(
  '-i', $InputFile,
  '-map','0'
)

# Set encoder
switch ($Encoder) {
  'amf' {$encodeargs += $AMFARGS}
  'nvenc' {$encodeargs += $NVENCARGS}
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
  ":max-cll=0,0"

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
& ffmpeg @encodeargs