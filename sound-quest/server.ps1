param(
  [int]$Port = 8787
)

$ErrorActionPreference = "Stop"

$BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$HtmlFile = Join-Path $BaseDir "index.html"
$CacheDir = Join-Path $BaseDir "audio-cache"
$EnvFile = Join-Path $BaseDir ".env"

if (-not (Test-Path $CacheDir)) {
  New-Item -ItemType Directory -Path $CacheDir | Out-Null
}

if (Test-Path $EnvFile) {
  Get-Content $EnvFile -Encoding UTF8 | ForEach-Object {
    $line = $_.Trim()
    if (-not $line -or $line.StartsWith("#") -or -not $line.Contains("=")) {
      return
    }
    $parts = $line.Split("=", 2)
    $name = $parts[0].Trim()
    $value = $parts[1].Trim().Trim('"').Trim("'")
    if (-not [Environment]::GetEnvironmentVariable($name, "Process")) {
      [Environment]::SetEnvironmentVariable($name, $value, "Process")
    }
  }
}

function Write-Response {
  param(
    [System.Net.HttpListenerResponse]$Response,
    [int]$StatusCode,
    [byte[]]$Bytes,
    [string]$ContentType
  )

  $Response.StatusCode = $StatusCode
  $Response.ContentType = $ContentType
  $Response.ContentLength64 = $Bytes.Length
  $Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
  $Response.OutputStream.Close()
}

function Write-Text {
  param(
    [System.Net.HttpListenerResponse]$Response,
    [int]$StatusCode,
    [string]$Text
  )

  Write-Response -Response $Response -StatusCode $StatusCode -Bytes ([Text.Encoding]::UTF8.GetBytes($Text)) -ContentType "text/plain; charset=utf-8"
}

function Get-SafeAudioName {
  param([string]$Text)

  $slug = ($Text.ToLower() -replace "[^a-z0-9_-]+", "-").Trim("-")
  if (-not $slug) {
    $slug = "word"
  }

  $sha = [System.Security.Cryptography.SHA1]::Create()
  $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))
  $digest = -join ($hash[0..4] | ForEach-Object { $_.ToString("x2") })
  return "$slug-$digest.mp3"
}

function Invoke-OpenAITts {
  param([string]$Text)

  $apiKey = [Environment]::GetEnvironmentVariable("OPENAI_API_KEY", "Process")
  if (-not $apiKey) {
    throw "OPENAI_API_KEY is missing. Create outputs\sound-quest\.env first."
  }

  $model = [Environment]::GetEnvironmentVariable("OPENAI_TTS_MODEL", "Process")
  if (-not $model) {
    $model = "gpt-4o-mini-tts"
  }

  $voice = [Environment]::GetEnvironmentVariable("OPENAI_TTS_VOICE", "Process")
  if (-not $voice) {
    $voice = "alloy"
  }

  $instructions = [Environment]::GetEnvironmentVariable("OPENAI_TTS_INSTRUCTIONS", "Process")
  if (-not $instructions) {
    $instructions = "Pronounce this as a clear American English phonics word for a second-grade child. Say only the word, with no extra explanation."
  }

  $body = @{
    model = $model
    voice = $voice
    input = $Text
    response_format = "mp3"
    instructions = $instructions
  } | ConvertTo-Json

  $headers = @{
    Authorization = "Bearer $apiKey"
  }

  $tempFile = Join-Path $CacheDir ("tmp-" + [Guid]::NewGuid().ToString() + ".mp3")
  Invoke-WebRequest -Uri "https://api.openai.com/v1/audio/speech" -Method Post -Headers $headers -ContentType "application/json" -Body $body -OutFile $tempFile | Out-Null
  $bytes = [IO.File]::ReadAllBytes($tempFile)
  Remove-Item $tempFile -Force
  return $bytes
}

$listener = [System.Net.HttpListener]::new()
$prefix = "http://127.0.0.1:$Port/"
$listener.Prefixes.Add($prefix)
$listener.Start()

Write-Host "Sound Quest running at $prefix"
Write-Host "Press Ctrl+C to stop."

try {
  while ($listener.IsListening) {
    $context = $listener.GetContext()
    $request = $context.Request
    $response = $context.Response

    try {
      if ($request.Url.AbsolutePath -eq "/" -or $request.Url.AbsolutePath -eq "/index.html") {
        if (-not (Test-Path $HtmlFile)) {
          Write-Text -Response $response -StatusCode 404 -Text "index.html not found"
          continue
        }
        Write-Response -Response $response -StatusCode 200 -Bytes ([IO.File]::ReadAllBytes($HtmlFile)) -ContentType "text/html; charset=utf-8"
        continue
      }

      if ($request.Url.AbsolutePath -eq "/api/tts") {
        $word = $request.QueryString["word"]
        if (-not $word -or $word -notmatch "^[A-Za-z][A-Za-z'-]{0,30}$") {
          Write-Text -Response $response -StatusCode 400 -Text "Invalid word"
          continue
        }

        $audioPath = Join-Path $CacheDir (Get-SafeAudioName -Text $word)
        if (Test-Path $audioPath) {
          Write-Response -Response $response -StatusCode 200 -Bytes ([IO.File]::ReadAllBytes($audioPath)) -ContentType "audio/mpeg"
          continue
        }

        $audio = Invoke-OpenAITts -Text $word
        [IO.File]::WriteAllBytes($audioPath, $audio)
        Write-Response -Response $response -StatusCode 200 -Bytes $audio -ContentType "audio/mpeg"
        continue
      }

      if ($request.Url.AbsolutePath.StartsWith("/audio/")) {
        $relativePath = $request.Url.AbsolutePath.TrimStart("/") -replace "/", [IO.Path]::DirectorySeparatorChar
        $filePath = [IO.Path]::GetFullPath((Join-Path $BaseDir $relativePath))
        $basePath = [IO.Path]::GetFullPath($BaseDir)
        if ($filePath.StartsWith($basePath) -and (Test-Path $filePath)) {
          Write-Response -Response $response -StatusCode 200 -Bytes ([IO.File]::ReadAllBytes($filePath)) -ContentType "audio/mp4"
          continue
        }
      }

      Write-Text -Response $response -StatusCode 404 -Text "Not found"
    } catch {
      Write-Text -Response $response -StatusCode 500 -Text $_.Exception.Message
    }
  }
} finally {
  $listener.Stop()
}
