# FFMPEG-WRAPPERS
Exactly what it says on the tin: a set of scripts that are meant to wrap ffmpeg
execution. These scripts were constructed for my own use but are intented to
include sane defaults with enough flexibility to adapt to most situations.

## Installation
  1. Install ffmpeg; ensure the executable is in PATH
  2. Copy scripts locally (or just clone this repo)
  3. Run the script you need.

## Scripts
### Resize-HDR.ps1
Designed to crop letterboxing or pillar boxing from a file; HDR metadata will be preserved and all audio and subtitle streams will be copied to the output file.

#### Parameters

* **InputFile** - Full path to the source file to be cropped and transcoded. This parameter is mandatory.
* **OutputFile** - Full path to the file to output once cropping and transcoding are done. This parameter is optional, if it's not specified a new file will be created in the same directory as the input file with `_output.mkv` appeneded to the filename.
* **Encoder** - Optional, only accepts libx265; the various hardware accelerated encoders do not support adding the HDR metadata to the frames at this time.
* **CRF** - Quality to use when transcoding; lower numbers result in higher quality and larger file sizes. For a more complete explanation check the ffmpeg docs on rate control options. This script does not support target bitrates or target sizes.
* **Tune** - x265 supports `grain` and `animation` tunes to better preserve film grain and improve compression of animated content. If you don`t need either of these leave it blank.
* **Preset** - x265 has various presets for compression options, in general slower gives you more visual quality per encoded bit resulting in either smaller file sizes or higher percieved quality for the same file size. Can be any of `ultrafast`, `superfast`, `veryfast`, `faster`, `fast`, `medium`, `slow`, `slower`, `veryslow`.
* **CropScan** - Seconds of the input file to scan when detecting how much of the display area to crop; defaults to 300 seconds (5 minutes). If you find that parts of the image are being cut off try extending this.
* **DisableHardwareDecode** - By default this script will try to use hardware acceleration for decoding the input file; this will fail if it's run on a device (eg VirtualMachine) that doesn't have the ability to decode the source format in hardware. Use this flag if you want to force software decoding.