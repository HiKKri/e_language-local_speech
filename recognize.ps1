#==================================================
# recognize.ps1 - SAPI Speech Recognition
# Usage: powershell -ExecutionPolicy Bypass -NoProfile -File recognize.ps1 -WavFile <wav> -ResultFile <result>
#==================================================
param(
    [Parameter(Mandatory=$true)][string]$WavFile,
    [Parameter(Mandatory=$true)][string]$ResultFile
)

# Use GBK encoding for output file (matches EPL's default text reading)
$gbkEncoding = [System.Text.Encoding]::GetEncoding("GB2312")

try {
    Add-Type -AssemblyName System.Speech

    # --- Check WAV file ---
    if (-not (Test-Path $WavFile)) {
        [System.IO.File]::WriteAllText($ResultFile, "[ERROR] WAV file not found: $WavFile", $gbkEncoding)
        exit 1
    }
    $fileInfo = Get-Item $WavFile
    if ($fileInfo.Length -lt 100) {
        [System.IO.File]::WriteAllText($ResultFile, "[ERROR] WAV file too small: $($fileInfo.Length) bytes", $gbkEncoding)
        exit 1
    }

    # --- Read WAV format from file header ---
    $bytes = [System.IO.File]::ReadAllBytes($WavFile)
    $sampleRate = [BitConverter]::ToInt32($bytes, 24)
    $channels = [BitConverter]::ToInt16($bytes, 22)
    $bitsPerSample = [BitConverter]::ToInt16($bytes, 34)
    $formatTag = [BitConverter]::ToInt16($bytes, 20)

    # --- Convert to 16kHz mono if needed using raw PCM decode + resample ---
    # System.Speech needs: 16kHz, 16bit, mono, PCM
    $needConvert = ($sampleRate -ne 16000 -or $channels -ne 1 -or $bitsPerSample -ne 16 -or $formatTag -ne 1)

    if ($needConvert) {
        # Use SoundTouch or simple downsampling
        # Simple approach: use System.Speech.Synthesis to create a converted WAV
        # Actually use AudioFileReader approach with NAudio if available
        # Fallback: use ffmpeg if available
        $ffmpeg = Get-Command ffmpeg -ErrorAction SilentlyContinue
        if ($ffmpeg) {
            $convertedWav = [System.IO.Path]::GetTempFileName() + ".wav"
            & ffmpeg -y -i $WavFile -ar 16000 -ac 1 -sample_fmt s16 $convertedWav 2>$null
            if (Test-Path $convertedWav) {
                $WavFile = $convertedWav
            }
        } else {
            # Manual PCM extraction and simple resample
            # Find data chunk
            $dataOffset = 12
            $dataLen = 0
            while ($dataOffset -lt $bytes.Length - 8) {
                $chunkId = [System.Text.Encoding]::ASCII.GetString($bytes, $dataOffset, 4)
                $chunkLen = [BitConverter]::ToInt32($bytes, $dataOffset + 4)
                if ($chunkId -eq "data") {
                    $dataLen = $chunkLen
                    $dataOffset += 8
                    break
                }
                $dataOffset += 8 + $chunkLen
                if ($chunkLen % 2 -ne 0) { $dataOffset += 1 }
            }

            if ($dataLen -gt 0 -and $bitsPerSample -eq 16 -and $formatTag -eq 1) {
                # Extract 16-bit samples
                $sampleCount = [int]($dataLen / 2 / $channels)
                $samples = New-Object 'int[]' $sampleCount
                for ($i = 0; $i -lt $sampleCount; $i++) {
                    $offset = $dataOffset + $i * $channels * 2
                    if ($channels -eq 2) {
                        $left = [BitConverter]::ToInt16($bytes, $offset)
                        $right = [BitConverter]::ToInt16($bytes, $offset + 2)
                        $samples[$i] = [int](($left + $right) / 2)
                    } else {
                        $samples[$i] = [BitConverter]::ToInt16($bytes, $offset)
                    }
                }

                # Simple decimation resample to 16kHz
                $ratio = [double]$sampleRate / 16000.0
                $newSampleCount = [int]($sampleCount / $ratio)
                $newSamples = New-Object 'int16[]' $newSampleCount
                for ($i = 0; $i -lt $newSampleCount; $i++) {
                    $srcIdx = [int]($i * $ratio)
                    if ($srcIdx -ge $sampleCount) { $srcIdx = $sampleCount - 1 }
                    $newSamples[$i] = $samples[$srcIdx]
                }

                # Write new WAV file
                $convertedWav = [System.IO.Path]::GetTempFileName() + ".wav"
                $newDataLen = $newSampleCount * 2
                $newFileLen = 36 + $newDataLen
                $header = New-Object 'byte[]' 44
                [System.Text.Encoding]::ASCII.GetBytes("RIFF").CopyTo($header, 0)
                [BitConverter]::GetBytes([int]($newFileLen)).CopyTo($header, 4)
                [System.Text.Encoding]::ASCII.GetBytes("WAVE").CopyTo($header, 8)
                [System.Text.Encoding]::ASCII.GetBytes("fmt ").CopyTo($header, 12)
                [BitConverter]::GetBytes([int]16).CopyTo($header, 16)
                [BitConverter]::GetBytes([int16]1).CopyTo($header, 20)
                [BitConverter]::GetBytes([int16]1).CopyTo($header, 22)
                [BitConverter]::GetBytes([int]16000).CopyTo($header, 24)
                [BitConverter]::GetBytes([int]32000).CopyTo($header, 28)
                [BitConverter]::GetBytes([int16]2).CopyTo($header, 32)
                [BitConverter]::GetBytes([int16]16).CopyTo($header, 34)
                [System.Text.Encoding]::ASCII.GetBytes("data").CopyTo($header, 36)
                [BitConverter]::GetBytes([int]$newDataLen).CopyTo($header, 40)

                $outBytes = New-Object 'byte[]' (44 + $newDataLen)
                [Array]::Copy($header, 0, $outBytes, 0, 44)
                [Buffer]::BlockCopy($newSamples, 0, $outBytes, 44, $newDataLen)
                [System.IO.File]::WriteAllBytes($convertedWav, $outBytes)

                $WavFile = $convertedWav
            }
        }
    }

    # --- Create recognition engine ---
    $engine = New-Object System.Speech.Recognition.SpeechRecognitionEngine
    $engine.SetInputToWaveFile($WavFile)

    $audioFormat = $engine.AudioFormat
    $formatInfo = "unknown"
    if ($audioFormat -ne $null) {
        $formatInfo = "$($audioFormat.SamplesPerSecond)Hz, $($audioFormat.BitsPerSample)bit, $($audioFormat.Channels)ch"
    }

    # --- Load dictation grammar ---
    $grammar = New-Object System.Speech.Recognition.DictationGrammar
    $engine.LoadGrammar($grammar)

    # --- Loop recognition with real-time output ---
    # Each recognized phrase is immediately written to result file
    # EPL clock polls file and updates edit box in real-time
    $allText = ""
    $timeout = New-Object System.TimeSpan(0, 0, 10)
    $doneFile = $ResultFile + ".done"

    # Remove old done file
    if (Test-Path $doneFile) { Remove-Item $doneFile -Force }

    do {
        $result = $engine.Recognize($timeout)
        if ($result -ne $null -and $result.Text -ne $null -and $result.Text -ne "") {
            $allText += $result.Text
            # Write current progress to result file (GBK)
            if (Test-Path $ResultFile) { Remove-Item $ResultFile -Force }
            [System.IO.File]::WriteAllText($ResultFile, $allText, $gbkEncoding)
        }
    } while ($result -ne $null)

    # --- Final write (if nothing was recognized) ---
    if ($allText -eq "") {
        $msg = "[ERROR] No speech recognized. Audio format: $formatInfo. File: $($fileInfo.Length) bytes."
        if (Test-Path $ResultFile) { Remove-Item $ResultFile -Force }
        [System.IO.File]::WriteAllText($ResultFile, $msg, $gbkEncoding)
    }

    # --- Write done marker file ---
    [System.IO.File]::WriteAllText($doneFile, "done", $gbkEncoding)

    $engine.Dispose()

    # --- Clean up temp wav file ---
    if ($WavFile -ne $PSBoundParameters.WavFile -and (Test-Path $WavFile)) {
        Remove-Item $WavFile -Force -ErrorAction SilentlyContinue
    }

} catch {
    $errMsg = "[ERROR] $($_.Exception.Message)"
    if (Test-Path $ResultFile) { Remove-Item $ResultFile -Force }
    [System.IO.File]::WriteAllText($ResultFile, $errMsg, $gbkEncoding)
    # Write done marker even on error
    $doneFile = $ResultFile + ".done"
    [System.IO.File]::WriteAllText($doneFile, "done", $gbkEncoding)
    exit 1
}
