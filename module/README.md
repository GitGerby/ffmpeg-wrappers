<!--
 Copyright 2022 GearnsC
 
 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at
 
     http://www.apache.org/licenses/LICENSE-2.0
 
 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
-->

# Transcode

This module is an attempt to productionize some of the code I've put together to
wrap ffmpeg for nvenc archival transcodes. I may extend support in the future
for additional encoders. All functions below support cmdlet binding and
`-Verbose` may be of particular interest.

## Start-Transcode

* Video tracks are transcoded to HEVC with nvenc.
* Video is cropped to remove letterboxing and pillarboxing.
* Audio tracks are copied as is.
* Subtitles are copied as is.
* External SRT files matching the Source file name are injected as additional
  subtitle tracks in the destination file.
* Output file is placed on the pipeline.

### Params

* `-Source` Source file to be transcoded.
* `-Destination` Output file for transcode.
* `-Crop` String specifying a crop filter; if provided will be used in place of
  automatic crop detection.
* `-Crf` Quality value to pass to NVENC's CRF arg.
* `-Filters` Custom filter string appended to the crop filter for additional 
  processing.
* `-NoCrop` Do not crop the video; disables auto crop detection.
* `-Language` Language to filter metadata on when copying audio tracks and
  subtitles; defaults to `eng`. Will also be used to set metadata of injected
  srt files.
* `-FfmpegPath` Path to the ffmpeg binary to use for this transcode. If blank an
  attempt will be made to automatically detect the location of ffmpeg with a
  fallback to prompting the user.
* `-Overwrite` If specified will overwrite any existing destination file.

## Set-FfmpegPath

Stores the path to the ffmpeg binary that should be used by other functions from
this module.

### Params

* `-Path`: Specifies the path to the binary to use for other functions from this
module. If not specified on the commandline the user is prompted for the path.

## Get-Crop

Scans the first 300 seconds of a specified file to determine the appropriate
ffmpeg crop filter settings to eliminate black bars from letterboxing or
pillarboxing

### Params

* `-Source` File to generate crop filter from.
