# FFMPEG-WRAPPERS

Exactly what it says on the tin: a set of scripts that are meant to wrap ffmpeg
execution. These scripts were constructed for my own use but are intended to
include sane defaults with enough flexibility to adapt to most situations.

## Installation

  1. Install ffmpeg; ensure the executable is in PATH
  2. Copy scripts locally (or just clone this repo)
  3. Run the script you need.

## Scripts

### Common Parameters

* **InputFile** - Full path to the source file to be cropped and transcoded. This parameter is mandatory.
* **OutputFile** - Full path to the file to output once cropping and transcoding are done. This parameter is optional, if it's not specified a new file will be created in the same directory as the input file with `_output.mkv` appeneded to the filename.

* **CRF** - Quality to use when transcoding; lower numbers result in higher quality and larger file sizes. For a more complete explanation check the ffmpeg docs on rate control options. This script does not support target bitrates or target sizes.
* **Tune** - x265 supports the `grain` and `animation` tunes to better preserve film grain or improve compression of animated content. If you don't need either of these leave it blank.
* **Preset** - x265 has various presets for compression options, in general slower options gives you more visual quality per encoded bit resulting in either smaller file sizes or higher percieved quality for the same file size. Can be any of `ultrafast`, `superfast`, `veryfast`, `faster`, `fast`, `medium`, `slow`, `slower`, `veryslow`.
* **CropScan** - Seconds of the input file to scan when detecting how much of the display area to crop; defaults to 300 seconds (5 minutes). If you find that parts of the image are being cut off try extending this.
* **DisableHardwareDecode** - By default this script will try to use hardware acceleration for decoding the input file; this will fail if it's run on a device (eg VirtualMachine) that doesn't have the ability to decode the source format in hardware. Use this flag if you want to force software decoding.

### Resize-HDR.ps1

Designed to crop letter or pillar boxing from a file; HDR metadata will be preserved and all audio and subtitle streams will be copied to the output file.

#### Parameters

* **Encoder** - Optional, only accepts `libx265`; the various hardware accelerated encoders do not support adding the HDR metadata to the frames at this time.

### ConvertTo-SDR.ps1

This script tonemaps an HDR file to SDR and by default will crop any black bars for letter or pillar boxing. All audio and subtitle streams will be copied to the output file. This script will work best on systems that have OpenCL support to accelerate the tonemapping.

#### Parameters

* **Encoder** - Optional, accepts `libx265`, `nvenc`, and `qsv` at this time; defaults to `nvenc`. `nvenc` and `qsv` rely on the underlying hardware support; `nvenc` requires an nVidia gpu that supports HEVC encoding while `qsv` requires Intel Quicksync support for HEVC.
* **DoNotCrop** - Don't crop black bars from the output file.
* **DisableOpenCL** - Disables OpenCl tonemapping; this results in the tonemapping filter running on the CPU; expect it to be slow. Necessary on machines that don't have hardware that supports OpenCL.
* **GpuIndex** - Specify the GPU to use for OpenCL tasks; defaults to the first GPU on the system `0.0`.
* **ToneMapMethod** - Specify the tone mapping algorithm to use; can be any of `none`, `clip`, `linear`, `gamma`, `reinhard`, `hable`, `mobius`. See the ffmpeg documentation for a description of each. Defaults to `hable`.
