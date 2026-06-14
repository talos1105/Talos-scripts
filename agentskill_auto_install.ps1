# agentskill_auto_install.ps1 -- Runs without Administrator privileges
#
# First run: Unblock-File .\agentskill_auto_install.ps1
# Usage:     .\agentskill_auto_install.ps1
#            .\agentskill_auto_install.ps1 -Platform vscode
#            .\agentskill_auto_install.ps1 -Platform codex
#            .\agentskill_auto_install.ps1 -AutoStart          # register auto-start without prompting
#            .\agentskill_auto_install.ps1 -SkipPrompts        # answer Y to ALL interactive prompts
#
# CLAUDE_CONFIG_DIR:
#   If set, skills are installed into $CLAUDE_CONFIG_DIR\skills\
#   Example: $env:CLAUDE_CONFIG_DIR = "D:\workspace\.claude"
#   If not set, falls back to: %USERPROFILE%\.claude

param(
    [string]$Platform    = "",
    [switch]$AutoStart,      # Register Task Scheduler task so agentmemory starts with Windows (no prompt)
    [switch]$SkipPrompts,    # Skip ALL interactive Y/N questions -- implies AutoStart
    [switch]$StartServer     # Headless server-only mode -- called by Task Scheduler at logon, do not run manually
)

$ErrorActionPreference = "Stop"

# ============================================================
# STARTUP MODE: -StartServer
# Task Scheduler calls this script with -StartServer at logon.
# Runs the agentmemory server headlessly and exits -- the rest
# of the install logic is completely skipped.
# ============================================================
if ($StartServer) {
    $sc_claudeDir  = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR.TrimEnd('\') } `
                     else { "$env:USERPROFILE\.claude" }
    $sc_binDir     = Join-Path $sc_claudeDir "bin"
    $sc_iiiDir     = "$env:USERPROFILE\.agentmemory\bin"
    $sc_log        = Join-Path $sc_claudeDir "agentmemory.log"
    $sc_npmPfx     = try { (npm config get prefix 2>$null).Trim() } catch { "" }
    $sc_cliMjs     = Join-Path $sc_npmPfx "node_modules\@agentmemory\agentmemory\dist\cli.mjs"

    # Skip if server already running
    $curlExe = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curlExe) {
        $code = & curl.exe -s -o NUL -w "%{http_code}" --max-time 3 `
                    "http://127.0.0.1:3111/agentmemory/health" 2>$null
        if ($code -eq "200") { exit 0 }
    }

    if (-not (Test-Path $sc_cliMjs)) {
        $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Add-Content $sc_log "[$ts] ERROR: cli.mjs not found at $sc_cliMjs"
        exit 1
    }

    $env:PATH = "$sc_binDir;$env:PATH"
    Set-Location $sc_iiiDir

    $pinfo = New-Object System.Diagnostics.ProcessStartInfo
    $pinfo.FileName               = "node"
    $pinfo.Arguments              = "`"$sc_cliMjs`""
    $pinfo.UseShellExecute        = $false
    $pinfo.RedirectStandardInput  = $true
    $pinfo.CreateNoWindow         = $true
    $pinfo.WorkingDirectory       = $sc_iiiDir
    $pinfo.EnvironmentVariables["PATH"] = "$sc_binDir;$env:PATH"

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $pinfo
    $proc.Start() | Out-Null
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content $sc_log "[$ts] agentmemory started (PID $($proc.Id))"

    # Wait for TUI to render then send Enter (select iii -- first option)
    Start-Sleep -Seconds 4
    try { $proc.StandardInput.Write([char]13); $proc.StandardInput.Flush() } catch {}
    exit 0
}

function Log  { Write-Host "  [OK] $args" -ForegroundColor Green }
function Warn { Write-Host "  [!!] $args" -ForegroundColor Yellow }
function Info { Write-Host "  --> $args" -ForegroundColor Cyan }
function Head { Write-Host ""; Write-Host "=== $args ===" -ForegroundColor White }
function Fail { Write-Host "  [X] $args" -ForegroundColor Red; exit 1 }
function Has  { param([string]$cmd) return $null -ne (Get-Command $cmd -ErrorAction SilentlyContinue) }

# -- Resolve Claude config directory -----------------------
Write-Host ""
Write-Host "=== Claude config directory ===" -ForegroundColor White

if ($env:CLAUDE_CONFIG_DIR -and $env:CLAUDE_CONFIG_DIR.Trim() -ne "") {
    $claudeDir = $env:CLAUDE_CONFIG_DIR.TrimEnd('\').TrimEnd('/')
    Write-Host "  [ENV] CLAUDE_CONFIG_DIR already set: $claudeDir" -ForegroundColor Magenta
} elseif ($SkipPrompts) {
    $claudeDir = "$env:USERPROFILE\.claude"
    Write-Host "  [--> ] SkipPrompts: using default: $claudeDir" -ForegroundColor DarkGray
} else {
    Write-Host ""
    Write-Host "  Use a custom Claude config directory?" -ForegroundColor White
    Write-Host "  Default: $env:USERPROFILE\.claude" -ForegroundColor DarkGray
    Write-Host "  Tip: re-run with -SkipPrompts to accept all defaults silently." -ForegroundColor DarkGray
    Write-Host ""
    $answer = (Read-Host "  Set custom path? (Y/N)").Trim().ToUpper()

    if ($answer -eq "Y") {
        do {
            $inputPath = (Read-Host "  Enter path (e.g. D:\workspace\.claude)").Trim().Trim('"')
            if ($inputPath -eq "") { Write-Host "  Path cannot be empty." -ForegroundColor Yellow }
        } while ($inputPath -eq "")

        $claudeDir = $inputPath.TrimEnd('\').TrimEnd('/')
        $env:CLAUDE_CONFIG_DIR = $claudeDir
        Write-Host "  [OK] Using: $claudeDir" -ForegroundColor Green

        $savePerm = (Read-Host "  Save permanently to User environment? (Y/N)").Trim().ToUpper()
        if ($savePerm -eq "Y") {
            [Environment]::SetEnvironmentVariable("CLAUDE_CONFIG_DIR", $claudeDir, "User")
            Write-Host "  [OK] Saved permanently (User scope)." -ForegroundColor Green
        } else {
            Write-Host "  [!!] Session only." -ForegroundColor Yellow
        }
    } else {
        $claudeDir = "$env:USERPROFILE\.claude"
        Write-Host "  [--> ] Using default: $claudeDir" -ForegroundColor DarkGray
    }
}

$baseDir         = Split-Path $claudeDir -Parent
$globalSkillsDir = Join-Path $claudeDir "skills"

# -- Install-SkillsGlobal ----------------------------------
# Clones a repo, auto-detects skills subfolder, copies all SKILL.md
# files into $globalSkillsDir. Bypasses npx skills@latest which does
# not support global installation for PromptScript format.
function Install-SkillsGlobal {
    param([string]$RepoUrl, [string]$RepoName, [string]$DestDir)

    $tempDir   = "$env:TEMP\skills_install_$RepoName"
    $noiseDirs = @('.git','node_modules','docs','assets','.github','scripts','references','hooks')

    if (Test-Path $tempDir -PathType Container) {
        Info "Updating cached repo: $RepoName ..."
        git -C $tempDir pull --quiet
    } else {
        Info "Cloning $RepoName ..."
        git clone --quiet $RepoUrl $tempDir
    }

    # Auto-detect skills root
    $searchRoot = $tempDir
    foreach ($candidate in @("skills", ".claude\skills", "src\skills")) {
        $p = Join-Path $tempDir $candidate
        if (Test-Path $p -PathType Container) {
            $searchRoot = $p
            Info "Skills root detected: $candidate\"
            break
        }
    }
    if ($searchRoot -eq $tempDir) {
        Info "No standard subfolder found -- scanning entire repo."
    }

    New-Item -ItemType Directory -Force -Path $DestDir | Out-Null

    $skillFiles = Get-ChildItem -Path $searchRoot -Recurse -Filter "SKILL.md" -ErrorAction SilentlyContinue |
            Where-Object {
                $fp = $_.FullName
                -not ($noiseDirs | Where-Object { $fp -like "*\$_\*" })
            }

    if ($null -eq $skillFiles -or $skillFiles.Count -eq 0) {
        Warn "No SKILL.md files found in $RepoName. Skipping."
        return
    }

    $installed = 0
    foreach ($file in $skillFiles) {
        $skillName = $file.Directory.Name
        $dest      = Join-Path $DestDir $skillName
        New-Item -ItemType Directory -Force -Path $dest | Out-Null
        Copy-Item -Force $file.FullName (Join-Path $dest "SKILL.md")

        $scriptsDir = Join-Path $file.Directory.FullName "scripts"
        if (Test-Path $scriptsDir -PathType Container) {
            Copy-Item -Recurse -Force $scriptsDir (Join-Path $dest "scripts")
        }
        $installed++
    }

    Log "$installed skill(s) from $RepoName --> $DestDir"
}

# -- 0/10. Prerequisites ------------------------------------
Head "0/10  Checking prerequisites"

if (-not (Has "node")) {
    Warn "Node.js not found -- installation will be offered in the next step."
} else {
    $nodeVer = [int](node -e "process.stdout.write(process.versions.node.split('.')[0])")
    if ($nodeVer -lt 20) { Warn "Node.js $nodeVer detected -- version 20+ is recommended." }
    else { Log "Node.js $nodeVer" }
}

if (-not (Has "npm")) {
    Warn "npm not found -- installation will be offered in the next step."
} else {
    Log "npm $(npm -v)"
}

$PY = $null
if (Has "python") { $PY = "python" } elseif (Has "python3") { $PY = "python3" }
if ($null -ne $PY) { Log (& $PY --version 2>&1).ToString() }
else { Warn "Python not found -- pip-based steps will be skipped." }

if (-not (Has "git")) { Fail "git is required. Download from: https://git-scm.com" }
Log "git $(git --version)"

if (-not (Has "curl.exe")) { Warn "curl.exe not found -- health checks may not work." }

# Configure npm user-level prefix (no Admin required)
if (Has "npm") {
    $npmUserDir = "$env:APPDATA\npm"
    if (-not (Test-Path $npmUserDir)) { New-Item -ItemType Directory -Force -Path $npmUserDir | Out-Null }
    $currentPrefix = (npm config get prefix 2>$null).Trim()
    if ($currentPrefix -ne $npmUserDir) {
        Info "Redirecting npm prefix to user directory: $npmUserDir"
        npm config set prefix $npmUserDir
    }
    if ($env:PATH -notlike "*$npmUserDir*") {
        $env:PATH = "$npmUserDir;$env:PATH"
        $oldPath = [Environment]::GetEnvironmentVariable("PATH", "User")
        if ($oldPath -notlike "*$npmUserDir*") {
            [Environment]::SetEnvironmentVariable("PATH", "$npmUserDir;$oldPath", "User")
            Info "npm directory saved permanently to User PATH."
        }
    }
}

# -- 0a. Node.js / npm - Install if missing ----------------
if (-not (Has "node") -or -not (Has "npm")) {
    Head "0a  Node.js / npm - Installation"

    $nodeVersions = @(
        [PSCustomObject]@{ Label = "22.x LTS (Jod) -- Recommended"; Full = "22.16.0" }
        [PSCustomObject]@{ Label = "24.x LTS (Noble) -- Current";   Full = "24.2.0"  }
    )

    if ($SkipPrompts) {
        $nodeInstallType = "installer"
        $nodeSelected    = $nodeVersions[0]
        Info "SkipPrompts: installing Node.js $($nodeSelected.Full) (.msi)"
    } else {
        Write-Host ""
        Write-Host "  Node.js / npm is required but not found." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  Choose installation type:" -ForegroundColor White
        Write-Host "    [1] Portable (zip)  - extract only, no system install" -ForegroundColor Cyan
        Write-Host "    [2] Installer (.msi) - installs system-wide, adds to PATH" -ForegroundColor Cyan
        Write-Host "    [S] Skip" -ForegroundColor DarkGray
        $nodeTypeAns = (Read-Host "  Choice (1/2/S)").Trim().ToUpper()
        $nodeInstallType = switch ($nodeTypeAns) {
            "1"     { "portable"  }
            "2"     { "installer" }
            "S"     { "skip"      }
            default { "installer" }
        }

        if ($nodeInstallType -ne "skip") {
            Write-Host ""
            Write-Host "  Choose Node.js version:" -ForegroundColor White
            for ($ni = 0; $ni -lt $nodeVersions.Count; $ni++) {
                Write-Host ("    [{0}] {1}" -f ($ni + 1), $nodeVersions[$ni].Label) -ForegroundColor Cyan
            }
            Write-Host "    [C] Custom - enter version manually" -ForegroundColor DarkGray
            $nodeVerAns = (Read-Host "  Choice (1-$($nodeVersions.Count)/C)").Trim().ToUpper()

            if ($nodeVerAns -eq "C") {
                $customFull  = (Read-Host "  Enter full version (e.g. 22.16.0)").Trim()
                $nodeSelected = [PSCustomObject]@{ Label = "Custom"; Full = $customFull }
            } elseif ($nodeVerAns -match "^\d+$" -and [int]$nodeVerAns -ge 1 -and [int]$nodeVerAns -le $nodeVersions.Count) {
                $nodeSelected = $nodeVersions[[int]$nodeVerAns - 1]
            } else {
                $nodeSelected = $nodeVersions[0]
                Warn "Unrecognized input -- defaulting to $($nodeSelected.Label)"
            }
        }
    }

    if ($nodeInstallType -eq "skip") {
        Warn "Node.js installation skipped. npm-based steps in this script will not work."
    } elseif ($nodeInstallType -eq "portable") {
        $nodeArch   = if ([Environment]::Is64BitOperatingSystem) { "win-x64" } else { "win-x86" }
        $nodeZipUrl = "https://nodejs.org/dist/v$($nodeSelected.Full)/node-v$($nodeSelected.Full)-$nodeArch.zip"
        $nodeZipTmp = "$env:TEMP\node-v$($nodeSelected.Full)-$nodeArch.zip"
        $nodeDir    = Join-Path $PSScriptRoot "node-v$($nodeSelected.Full)"

        Info "Downloading Node.js $($nodeSelected.Full) portable (~25MB) ..."
        try {
            Invoke-WebRequest -Uri $nodeZipUrl -OutFile $nodeZipTmp -UseBasicParsing
            New-Item -ItemType Directory -Force -Path $nodeDir | Out-Null
            Expand-Archive -Path $nodeZipTmp -DestinationPath $nodeDir -Force
            # Zip extracts into a subfolder -- flatten one level
            $inner = Get-ChildItem $nodeDir -Directory | Select-Object -First 1
            if ($inner) {
                Get-ChildItem $inner.FullName | Move-Item -Destination $nodeDir -Force
                Remove-Item $inner.FullName -ErrorAction SilentlyContinue
            }
            Remove-Item $nodeZipTmp -Force -ErrorAction SilentlyContinue
            Log "Extracted to: $nodeDir"

            $env:PATH = "$nodeDir;$env:PATH"
            $oldPathN = [Environment]::GetEnvironmentVariable("PATH", "User")
            if ($oldPathN -notlike "*$nodeDir*") {
                [Environment]::SetEnvironmentVariable("PATH", "$nodeDir;$oldPathN", "User")
                Info "Added to User PATH: $nodeDir"
            }
            if (Has "node") { Log "node $(node -v) is now available." }
        } catch {
            Warn "Download failed: $($_.Exception.Message)"
            Warn "URL tried: $nodeZipUrl"
        }
    } elseif ($nodeInstallType -eq "installer") {
        $nodeMsi    = "node-v$($nodeSelected.Full)-x64.msi"
        $nodeMsiUrl = "https://nodejs.org/dist/v$($nodeSelected.Full)/$nodeMsi"
        $nodeMsiTmp = "$env:TEMP\$nodeMsi"

        Info "Downloading Node.js $($nodeSelected.Full) installer (~30MB) ..."
        try {
            Invoke-WebRequest -Uri $nodeMsiUrl -OutFile $nodeMsiTmp -UseBasicParsing
            Log "Downloaded: $nodeMsiTmp"
            Info "Launching installer (follow the UI -- ensure 'Add to PATH' is checked) ..."
            Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$nodeMsiTmp`" /qn ADDLOCAL=ALL" -Wait
            Log "Node.js installer finished."
            Remove-Item $nodeMsiTmp -Force -ErrorAction SilentlyContinue
            # Refresh PATH for current session
            $env:PATH = [Environment]::GetEnvironmentVariable("PATH","Machine") + ";" +
                        [Environment]::GetEnvironmentVariable("PATH","User")
            if (Has "node") { Log "node $(node -v) is now available." }
            else { Warn "'node' not in PATH yet -- restart PowerShell if commands fail." }
        } catch {
            Warn "Download failed: $($_.Exception.Message)"
            Warn "Install manually: https://nodejs.org"
        }
    }

    # Re-run npm prefix setup now that npm may be available
    if (Has "npm") {
        $npmUserDir = "$env:APPDATA\npm"
        if (-not (Test-Path $npmUserDir)) { New-Item -ItemType Directory -Force -Path $npmUserDir | Out-Null }
        $currentPrefix = (npm config get prefix 2>$null).Trim()
        if ($currentPrefix -ne $npmUserDir) {
            Info "Redirecting npm prefix to user directory: $npmUserDir"
            npm config set prefix $npmUserDir
        }
        if ($env:PATH -notlike "*$npmUserDir*") {
            $env:PATH = "$npmUserDir;$env:PATH"
            $oldPathN2 = [Environment]::GetEnvironmentVariable("PATH", "User")
            if ($oldPathN2 -notlike "*$npmUserDir*") {
                [Environment]::SetEnvironmentVariable("PATH", "$npmUserDir;$oldPathN2", "User")
                Info "npm directory saved permanently to User PATH."
            }
        }
    }
} else {
    Log "Node.js $(node -v) / npm $(npm -v) already installed -- skipping install step."
}

# -- 0b. Claude Code - Install if missing -------------------
Head "0b  Claude Code - Installation check"

if (Has "claude") {
    $ccVer = (claude --version 2>$null)
    Log "Claude Code already installed: $ccVer"
} else {
    Write-Host ""
    Write-Host "  Claude Code is not installed." -ForegroundColor Yellow
    Write-Host ""

    $doInstallClaude = $false
    if ($SkipPrompts) {
        $doInstallClaude = $true
        Info "SkipPrompts: installing Claude Code..."
    } else {
        Write-Host "  Would you like to install Claude Code?" -ForegroundColor White
        Write-Host "  Command: npm install -g @anthropic-ai/claude-code" -ForegroundColor DarkGray
        Write-Host ""
        $claudeAns = (Read-Host "  Install Claude Code? (Y/N)").Trim().ToUpper()
        $doInstallClaude = ($claudeAns -eq "Y")
    }

    if ($doInstallClaude) {
        if (-not (Has "npm")) {
            Warn "npm is required to install Claude Code. Install Node.js first, then re-run."
        } else {
            try {
                Info "Installing Claude Code via npm (this may take a minute)..."
                npm install -g "@anthropic-ai/claude-code"
                if (Has "claude") {
                    $ccVer = (claude --version 2>$null)
                    Log "Claude Code installed: $ccVer"
                } else {
                    Warn "Installation completed but 'claude' was not found in PATH."
                    Warn "Restart PowerShell, then verify with: claude --version"
                }
            } catch {
                Warn "Installation failed: $($_.Exception.Message)"
                Warn "Retry manually: npm install -g @anthropic-ai/claude-code"
            }
        }
    } else {
        Info "Skipped. Install manually: npm install -g @anthropic-ai/claude-code"
    }
}


Head "1/10  rohitg00/agentmemory - Persistent memory server"
Info "Installing via npm global (user-level prefix, no admin required)..."
try {
    npm install -g "@agentmemory/agentmemory"
    Log "agentmemory installed successfully."
} catch {
    Warn "Installation failed: $($_.Exception.Message)"
    Warn "Fallback: npx @agentmemory/agentmemory"
}

# -- 2/10. mattpocock/skills --------------------------------
Head "2/10  mattpocock/skills - Real engineering skills"
try {
    Install-SkillsGlobal `
        -RepoUrl "https://github.com/mattpocock/skills.git" `
        -RepoName "mattpocock-skills" `
        -DestDir $globalSkillsDir
} catch {
    Warn "Installation failed: $($_.Exception.Message)"
    Warn "Clone manually: git clone https://github.com/mattpocock/skills"
}

# -- 3/10. addyosmani/agent-skills -------------------------
Head "3/10  addyosmani/agent-skills - Production engineering skills"
try {
    Install-SkillsGlobal `
        -RepoUrl "https://github.com/addyosmani/agent-skills.git" `
        -RepoName "addyosmani-agent-skills" `
        -DestDir $globalSkillsDir
} catch {
    Warn "Installation failed: $($_.Exception.Message)"
    Warn "Clone manually: git clone https://github.com/addyosmani/agent-skills"
}

# -- 4/10. Claude Office Skills ----------------------------
Head "4/10  Anthropic Claude - Office Skills (docx/pdf/pptx/xlsx/frontend)"
# NOTE: Anthropic does not publish a public GitHub repo for Claude Code skills.
# The URLs previously attempted (anthropics/claude-code-skills, anthropics/skills,
# anthropics/claude-skills) do NOT exist and cause "Repository not found" errors.
# Skills are distributed via the Claude Code app itself -- install them inside the app.
Warn "Anthropic skills are not available as a public GitHub repo."
Write-Host "  Install Claude Code skills from INSIDE the Claude Code app:" -ForegroundColor DarkGray
Write-Host "    npx skills@latest" -ForegroundColor DarkCyan
Write-Host "  Or add skill files manually into: $globalSkillsDir" -ForegroundColor DarkGray

# -- 5/10. microsoft/markitdown ----------------------------
Head "5/10  microsoft/markitdown - Convert Office/PDF/HTML to Markdown"
if ($null -ne $PY) {
    try {
        Info "Installing markitdown[all] via pip (user-level)..."
        & $PY -m pip install --user --upgrade --quiet "markitdown[all]"
        Log "markitdown[all] installed."
    } catch {
        try {
            Info "Retrying with base package (no optional extras)..."
            & $PY -m pip install --user --upgrade --quiet markitdown
            Log "markitdown installed (base, no extras)."
        } catch {
            Warn "pip install failed: $($_.Exception.Message)"
            Write-Host "    Retry: pip install `"markitdown[all]`" --user" -ForegroundColor DarkGray
        }
    }
    # Clone the repo so scripts/examples are available locally
    try {
        $mdDir = "$env:TEMP\skills_install_markitdown"
        if (Test-Path $mdDir -PathType Container) {
            Info "Updating cached markitdown repo..."
            git -C $mdDir pull --quiet
        } else {
            Info "Cloning microsoft/markitdown..."
            git clone --quiet "https://github.com/microsoft/markitdown.git" $mdDir
        }
        Log "markitdown repo: $mdDir"

        # Check if this repo ships any SKILL.md files and install them
        $mdSkills = Get-ChildItem -Path $mdDir -Recurse -Filter "SKILL.md" -ErrorAction SilentlyContinue
        if ($mdSkills -and $mdSkills.Count -gt 0) {
            Install-SkillsGlobal `
                -RepoUrl "https://github.com/microsoft/markitdown.git" `
                -RepoName "markitdown" `
                -DestDir $globalSkillsDir
        }
    } catch {
        Warn "Repo clone skipped: $($_.Exception.Message)"
    }
} else {
    Warn "Python not found -- skipping markitdown."
}

# -- 6/10. chopratejas/headroom ----------------------------
Head "6/10  chopratejas/headroom - Context-aware document processing"
# NOTE: pip install headroom-ai is NOT attempted here.
# headroom-ai has no pre-built wheel for Python 3.12+ on Windows and
# requires a Rust toolchain to compile -- this reliably fails.
# Use Docker instead (step 10e) or run manually:
#   docker run -d -p 8000:8000 ghcr.io/chopratejas/headroom:latest
#   $env:ANTHROPIC_BASE_URL = "http://localhost:8000"
#   claude

# Clone repo for SKILL.md detection only (no pip install)
try {
    Install-SkillsGlobal `
        -RepoUrl "https://github.com/chopratejas/headroom.git" `
        -RepoName "headroom" `
        -DestDir $globalSkillsDir
} catch {
    Warn "No SKILL.md found in headroom repo: $($_.Exception.Message)"
}
Info "headroom proxy: use Docker (step 10e) -- pip install skipped (requires Rust on Windows)."

# -- 7/10. Understand-Anything ------------------------------
Head "7/10  Lum1104/Understand-Anything - Codebase knowledge graph"

$uaSupported = @("gemini","codex","opencode","pi","openclaw","antigravity","vibe","vscode","hermes","cline","kimi")
$uaDir = Join-Path $baseDir ".understand-anything\repo"

if (($Platform -ne "") -and ($uaSupported -contains $Platform)) {
    Info "Installing Understand-Anything for platform: $Platform"
    try {
        $uaScript = (Invoke-WebRequest `
            "https://raw.githubusercontent.com/Lum1104/Understand-Anything/main/install.ps1" `
            -UseBasicParsing).Content
        Invoke-Expression $uaScript
        Log "Understand-Anything installed for $Platform."
    } catch {
        Warn "Remote installer failed: $($_.Exception.Message)"
    }
} else {
    Info "Cloning Understand-Anything to $uaDir ..."
    try {
        if (Test-Path $uaDir -PathType Container) {
            git -C $uaDir pull --quiet
            Info "Repository updated to latest."
        } else {
            New-Item -ItemType Directory -Force -Path (Split-Path $uaDir -Parent) | Out-Null
            git clone --quiet "https://github.com/Lum1104/Understand-Anything.git" $uaDir
        }
        Log "Understand-Anything cloned to: $uaDir"
    } catch {
        Warn "Clone failed: $($_.Exception.Message)"
    }
    Write-Host ""
    Warn "Claude Code: run the following inside the app:"
    Write-Host "    /plugin marketplace add Lum1104/Understand-Anything" -ForegroundColor DarkCyan
    Write-Host "    /plugin install understand-anything" -ForegroundColor DarkCyan
}

# -- 8/10. Python - Embedded zip or Full Installer ---------
Head "8/10  Python - Embedded zip or Full Installer"

# Latest patch per minor -- update these when new releases ship
$pyVersions = @(
    [PSCustomObject]@{ Minor = "3.13"; Full = "3.13.5" }
    [PSCustomObject]@{ Minor = "3.12"; Full = "3.12.10" }
    [PSCustomObject]@{ Minor = "3.11"; Full = "3.11.12" }
    [PSCustomObject]@{ Minor = "3.10"; Full = "3.10.17" }
)

# -- Choose type: embedded or installer --------------------
if ($SkipPrompts) {
    $pyType = "embedded"
    Info "SkipPrompts: type = embedded"
} else {
    Write-Host ""
    Write-Host "  Choose Python installation type:" -ForegroundColor White
    Write-Host "    [1] Embedded  - zip, self-contained, no system install" -ForegroundColor Cyan
    Write-Host "    [2] Installer - full .exe, installs to system" -ForegroundColor Cyan
    Write-Host "    [S] Skip" -ForegroundColor DarkGray
    $pyTypeAns = (Read-Host "  Choice (1/2/S)").Trim().ToUpper()
    $pyType = switch ($pyTypeAns) {
        "1"     { "embedded"  }
        "2"     { "installer" }
        "S"     { "skip"      }
        default { "embedded"  }
    }
}

if ($pyType -eq "skip") {
    Info "Python setup skipped."
} else {
    # -- Choose version ----------------------------------------
    if ($SkipPrompts) {
        $pySelected = $pyVersions[0]
        Info "SkipPrompts: version = $($pySelected.Full)"
    } else {
        Write-Host ""
        Write-Host "  Choose Python version:" -ForegroundColor White
        for ($vi = 0; $vi -lt $pyVersions.Count; $vi++) {
            Write-Host ("    [{0}] Python {1}  (latest patch: {2})" -f ($vi + 1), $pyVersions[$vi].Minor, $pyVersions[$vi].Full) -ForegroundColor Cyan
        }
        Write-Host "    [C] Custom - enter version manually" -ForegroundColor DarkGray
        $verAns = (Read-Host "  Choice (1-$($pyVersions.Count)/C)").Trim().ToUpper()

        if ($verAns -eq "C") {
            $customFull  = (Read-Host "  Enter full version (e.g. 3.13.4)").Trim()
            $customMinor = ($customFull -split '\.')[0..1] -join '.'
            $pySelected  = [PSCustomObject]@{ Minor = $customMinor; Full = $customFull }
        } elseif ($verAns -match "^\d+$" -and [int]$verAns -ge 1 -and [int]$verAns -le $pyVersions.Count) {
            $pySelected = $pyVersions[[int]$verAns - 1]
        } else {
            $pySelected = $pyVersions[0]
            Warn "Unrecognized input -- defaulting to Python $($pySelected.Full)"
        }
    }

    $pyMinor = $pySelected.Minor
    $pyFull  = $pySelected.Full
    $arch    = if ([Environment]::Is64BitOperatingSystem) { "amd64" } else { "win32" }
    Info "Selected: Python $pyFull ($arch)"

    # ==========================================================
    if ($pyType -eq "embedded") {
        # ==========================================================

        # -- Input path ----------------------------------------
        $pyMinorDigits    = ($pyMinor -split '\.')[1]          # "3.13" -> "13"
        $defaultEmbedPath = Join-Path $PSScriptRoot "python-v$pyMinorDigits"

        if ($SkipPrompts) {
            $pyEmbedDir = $defaultEmbedPath
            Info "SkipPrompts: path = $pyEmbedDir"
        } else {
            Write-Host ""
            Write-Host "  Embedded Python directory (Enter for default: $defaultEmbedPath)" -ForegroundColor White
            $inputPath  = (Read-Host "  Path").Trim().Trim('"')
            $pyEmbedDir = if ($inputPath -ne "") { $inputPath } else { $defaultEmbedPath }
        }
        $pyEmbedExe = Join-Path $pyEmbedDir "python.exe"

        # Download embedded zip if python.exe not already present
        if (-not (Test-Path $pyEmbedExe)) {
            $zipUrl = "https://www.python.org/ftp/python/$pyFull/python-$pyFull-embed-$arch.zip"
            $zipTmp = "$env:TEMP\python-$pyFull-embed-$arch.zip"
            Info "Downloading Python $pyFull embedded zip ..."
            try {
                Invoke-WebRequest -Uri $zipUrl -OutFile $zipTmp -UseBasicParsing
                New-Item -ItemType Directory -Force -Path $pyEmbedDir | Out-Null
                Expand-Archive -Path $zipTmp -DestinationPath $pyEmbedDir -Force
                Remove-Item $zipTmp -Force -ErrorAction SilentlyContinue
                Log "Extracted to: $pyEmbedDir"
            } catch {
                Warn "Download failed: $($_.Exception.Message)"
                Warn "URL tried: $zipUrl"
            }
        } else {
            Info "python.exe already exists -- skipping download."
        }

        if (Test-Path $pyEmbedExe) {
            # Configure ._pth: uncomment 'import site' so pip works
            $pthFile = Get-ChildItem $pyEmbedDir -Filter "python*._pth" -ErrorAction SilentlyContinue |
                    Select-Object -First 1
            if ($pthFile) {
                $pthContent = Get-Content $pthFile.FullName -Raw
                if ($pthContent -match "(?m)^#\s*import site") {
                    $newPthContent = $pthContent -replace "(?m)^#\s*import site", "import site"
                    # Write WITHOUT BOM -- PowerShell 5.1 UTF8 adds BOM which breaks Python path parsing
                    [System.IO.File]::WriteAllText(
                            $pthFile.FullName,
                            $newPthContent,
                            [System.Text.UTF8Encoding]::new($false)
                    )
                    Info "Enabled 'import site' in $($pthFile.Name)"
                } else {
                    Info "'import site' already active in $($pthFile.Name)"
                }
            } else {
                Warn "No ._pth file found -- pip may not work correctly."
            }

            # Install pip via get-pip.py
            # NOTE: wrap in try-catch -- $ErrorActionPreference="Stop" treats any stderr
            # output from a native exe as a terminating error, so "No module named pip"
            # would crash the script before we even get to install pip.
            $pipInstalled = $false
            $pipCheck     = ""
            try {
                $pipCheck     = & $pyEmbedExe -m pip --version 2>&1
                $pipInstalled = ($LASTEXITCODE -eq 0)
            } catch { $pipInstalled = $false }

            if ($pipInstalled) {
                Log "pip already installed: $pipCheck"
            } else {
                Info "Installing pip via get-pip.py ..."
                $getPipPath = Join-Path $pyEmbedDir "get-pip.py"
                try {
                    Invoke-WebRequest -Uri "https://bootstrap.pypa.io/get-pip.py" -OutFile $getPipPath -UseBasicParsing
                    & $pyEmbedExe $getPipPath
                    if ($LASTEXITCODE -eq 0) {
                        Log "pip installed in: $pyEmbedDir"
                        Remove-Item $getPipPath -Force -ErrorAction SilentlyContinue
                    } else {
                        Warn "pip installation failed (exit $LASTEXITCODE)."
                    }
                } catch {
                    Warn "Failed to install pip: $($_.Exception.Message)"
                }
            }

            # Add python.exe dir + Scripts subdir to User PATH
            $doAddPath = $SkipPrompts
            if (-not $SkipPrompts) {
                Write-Host ""
                $addPathAns = (Read-Host "  Add Python $pyFull to User PATH? (Y/N)").Trim().ToUpper()
                $doAddPath  = ($addPathAns -eq "Y")
            }
            if ($doAddPath) {
                $scriptsDir = Join-Path $pyEmbedDir "Scripts"
                foreach ($dir in @($pyEmbedDir, $scriptsDir)) {
                    $curPath = [Environment]::GetEnvironmentVariable("PATH", "User")
                    if ($curPath -notlike "*$dir*") {
                        [Environment]::SetEnvironmentVariable("PATH", "$dir;$curPath", "User")
                        $env:PATH = "$dir;$env:PATH"
                        Log "Added to User PATH: $dir"
                    } else {
                        Info "Already in PATH: $dir"
                    }
                }
            }
        }

        # ==========================================================
    } elseif ($pyType -eq "installer") {
        # ==========================================================

        $exeName      = "python-$pyFull-$arch.exe"
        $installerUrl = "https://www.python.org/ftp/python/$pyFull/$exeName"
        $installerTmp = "$env:TEMP\$exeName"

        Info "Downloading Python $pyFull installer (~25MB) ..."
        try {
            Invoke-WebRequest -Uri $installerUrl -OutFile $installerTmp -UseBasicParsing
            Log "Downloaded: $installerTmp"
            Info "Launching installer (follow the UI, tick 'Add to PATH') ..."
            Start-Process -FilePath $installerTmp -Wait
            Log "Installer finished."
            Remove-Item $installerTmp -Force -ErrorAction SilentlyContinue
        } catch {
            Warn "Download failed: $($_.Exception.Message)"
            Warn "Download manually: $installerUrl"
        }
    }
}

# -- 9/10. Claude Code summary ------------------------------
Head "9/10  Connecting to Claude Code"

Write-Host ""
Write-Host "  Directory layout:" -ForegroundColor Gray
Write-Host "  $baseDir\" -ForegroundColor DarkGray
Write-Host "    .claude\skills\              <-- skills installed here" -ForegroundColor DarkCyan
Write-Host "    .understand-anything\repo\   <-- codebase knowledge" -ForegroundColor DarkCyan
Write-Host ""
Write-Host "  Inside Claude Code app:" -ForegroundColor Gray
Write-Host "  /plugin marketplace add rohitg00/agentmemory" -ForegroundColor DarkCyan
Write-Host "  /plugin install agentmemory" -ForegroundColor DarkCyan
Write-Host ""
Write-Host "  /plugin marketplace add Lum1104/Understand-Anything" -ForegroundColor DarkCyan
Write-Host "  /plugin install understand-anything" -ForegroundColor DarkCyan

# -- 10/10. agentmemory vector database setup ----------------
Head "10/10  agentmemory - Vector database (iii-engine) setup"

$claudeBinDir  = Join-Path $claudeDir "bin"
$iiiExe        = Join-Path $claudeBinDir "iii.exe"
$agentWrapper  = Join-Path $claudeBinDir "agentmemory.cmd"
$agentLog      = Join-Path $claudeDir "agentmemory.log"
$iiiVersion    = "0.11.2"
$iiiUrl        = "https://github.com/iii-hq/iii/releases/download/iii/v$iiiVersion/iii-x86_64-pc-windows-msvc.zip"
$iiiDefaultDir = "$env:USERPROFILE\.agentmemory\bin"
$iiiDefaultExe = Join-Path $iiiDefaultDir "iii.exe"

New-Item -ItemType Directory -Force -Path $claudeBinDir | Out-Null
New-Item -ItemType Directory -Force -Path $iiiDefaultDir | Out-Null

# -- 10a. Download iii.exe ----------------------------------
# Copy to two locations:
#   $claudeDir\bin\iii.exe          -- on PATH via wrapper
#   ~/.agentmemory\bin\iii.exe      -- agentmemory default lookup (skips first-run prompt)
if ((Test-Path $iiiExe) -and (Test-Path $iiiDefaultExe)) {
    Info "iii.exe already installed in both locations."
} else {
    Info "Downloading iii-engine v$iiiVersion (~6MB)..."
    try {
        $iiiZip     = "$env:TEMP\iii-windows.zip"
        $iiiExtract = "$env:TEMP\iii-extract"

        Invoke-WebRequest $iiiUrl -OutFile $iiiZip -UseBasicParsing
        Expand-Archive -Path $iiiZip -DestinationPath $iiiExtract -Force

        Copy-Item "$iiiExtract\iii.exe" $iiiExe -Force
        Copy-Item "$iiiExtract\iii.exe" $iiiDefaultExe -Force

        Remove-Item $iiiZip, $iiiExtract -Recurse -Force

        Log "iii.exe --> $iiiExe"
        Log "iii.exe --> $iiiDefaultExe"
    } catch {
        Warn "Download failed: $($_.Exception.Message)"
        Warn "Download manually: $iiiUrl"
        Warn "Place iii.exe at: $iiiExe AND $iiiDefaultExe"
    }
}

# -- 10b. Create agentmemory.cmd wrapper --------------------
# Wrapper adds $claudeDir\bin to PATH so iii.exe is found by agentmemory
Info "Creating agentmemory.cmd wrapper..."
$npmPrefix = (npm config get prefix 2>$null).Trim()
$realAgent = Join-Path $npmPrefix "agentmemory.cmd"

$wrapperContent = "@echo off`r`n" +
        "rem agentmemory wrapper -- auto-generated`r`n" +
        "set `"PATH=$claudeBinDir;%PATH%`"`r`n" +
        "call `"$realAgent`" %*"

[System.IO.File]::WriteAllText($agentWrapper, $wrapperContent, [System.Text.Encoding]::ASCII)
Log "Wrapper: $agentWrapper"

# -- 10c. Add .claude\bin to PATH ---------------------------
if ($env:PATH -notlike "*$claudeBinDir*") {
    $env:PATH = "$claudeBinDir;$env:PATH"
    $oldPath3 = [Environment]::GetEnvironmentVariable("PATH", "User")
    if ($oldPath3 -notlike "*$claudeBinDir*") {
        [Environment]::SetEnvironmentVariable("PATH", "$claudeBinDir;$oldPath3", "User")
        Info "Added to User PATH: $claudeBinDir"
    }
}

# -- 10d. Start agentmemory ---------------------------------
# iii.exe is pre-installed to both locations so agentmemory starts
# without interactive prompts. Uses node cli.mjs directly to bypass
# cmd wrapper -- Node.js stdin pipe works better than cmd.exe.
Write-Host ""
if (-not (Test-Path $iiiExe)) {
    Warn "iii.exe not found -- skipping agentmemory start."
    Warn "Install iii.exe manually then run: & `"$agentWrapper`""
} else {
    Info "Starting agentmemory server..."
    $npmPrefix = (npm config get prefix 2>$null).Trim()
    $cliMjs    = Join-Path $npmPrefix "node_modules\@agentmemory\agentmemory\dist\cli.mjs"

    if (Test-Path $cliMjs) {
        $pinfo = New-Object System.Diagnostics.ProcessStartInfo
        $pinfo.FileName               = "node"
        $pinfo.Arguments              = "`"$cliMjs`""
        $pinfo.UseShellExecute        = $false
        $pinfo.RedirectStandardInput  = $true
        $pinfo.RedirectStandardOutput = $false
        $pinfo.RedirectStandardError  = $false
        $pinfo.CreateNoWindow         = $false
        $pinfo.WorkingDirectory       = $iiiDefaultDir
        $pinfo.EnvironmentVariables["PATH"] = "$claudeBinDir;$env:PATH"

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $pinfo
        $proc.Start() | Out-Null

        # Wait for TUI to render then send Enter (select first option)
        Start-Sleep -Seconds 4
        $proc.StandardInput.Write([char]13)
        $proc.StandardInput.Flush()
    } else {
        Warn "cli.mjs not found at: $cliMjs"
        Info "Falling back to wrapper in new window..."
        Start-Process "cmd.exe" -ArgumentList "/k `"$agentWrapper`"" -WindowStyle Normal
    }

    # Poll health check via curl.exe (bypasses proxy/IPv6 issues)
    Info "Waiting for server to be ready (up to 90s)..."
    $ready   = $false
    $timeout = 90
    $start   = Get-Date

    while (-not $ready -and ((Get-Date) - $start).TotalSeconds -lt $timeout) {
        Start-Sleep -Seconds 1
        Write-Host "  ." -NoNewline -ForegroundColor DarkGray
        $code = curl.exe -s -o NUL -w "%{http_code}" --max-time 2 "http://127.0.0.1:3111/agentmemory/health" 2>$null
        if ($code -eq "200") { $ready = $true }
    }
    Write-Host ""

    if ($ready) {
        Log "agentmemory server is up."
        try {
            $healthJson = curl.exe -s --max-time 3 "http://127.0.0.1:3111/agentmemory/health" 2>$null
            $health     = $healthJson | ConvertFrom-Json
            $viewerPort = if ($health.viewerPort) { $health.viewerPort } else { 3114 }
        } catch {
            $viewerPort = 3114
        }
        Write-Host "  Health : http://127.0.0.1:3111/agentmemory/health" -ForegroundColor DarkCyan
        Write-Host "  Viewer : http://localhost:$viewerPort" -ForegroundColor DarkCyan
    } else {
        Warn "Server did not respond within $timeout seconds."
        Write-Host "  If a window opened: complete setup there." -ForegroundColor DarkGray
        Write-Host "  Manual start: & `"$agentWrapper`"" -ForegroundColor DarkGray
    }
}

# -- 10e. Headroom Docker container (optional) -------------
Write-Host ""
Head "10e  headroom - Docker container setup"

if (Has "docker") {
    # Check if Docker daemon is running
    $dockerRunning = $false
    try {
        $dockerCheck = docker info 2>&1
        if ($LASTEXITCODE -eq 0) { $dockerRunning = $true }
    } catch { $dockerRunning = $false }

    if ($dockerRunning) {
        Info "Docker detected and running -- starting headroom container..."

        $headroomDockerfile = @'
FROM ghcr.io/chopratejas/headroom:latest

# Install Code-Aware extras
RUN pip install --no-cache-dir "headroom-ai[code]"
'@

        $headroomCompose = @'
version: "3.8"

services:
  headroom:
    build: .
    container_name: headroom
    ports:
      - "8000:8787"
    environment:
      - HEADROOM_CODE_AWARE_ENABLED=1
    restart: unless-stopped
'@

        $headroomTmp = Join-Path $env:TEMP "headroom-$(Get-Random)"
        New-Item -ItemType Directory -Path $headroomTmp -Force | Out-Null
        try {
            $headroomDockerfile | Set-Content "$headroomTmp\Dockerfile"     -Encoding UTF8
            $headroomCompose    | Set-Content "$headroomTmp\docker-compose.yml" -Encoding UTF8

            Push-Location $headroomTmp
            docker compose up --build -d
            $dockerExit = $LASTEXITCODE
            Pop-Location

            if ($dockerExit -eq 0) {
                Log "Headroom container started at: http://localhost:8000"

                # Wait for container to be healthy (up to 60s)
                Info "Waiting for headroom container health check ..."
                $hrReady = $false
                $hrStart = Get-Date
                while (-not $hrReady -and ((Get-Date) - $hrStart).TotalSeconds -lt 60) {
                    Start-Sleep -Seconds 2
                    try {
                        $hrHealth = docker exec headroom sh -c "curl -s http://localhost:8787/livez" 2>$null
                        if ($LASTEXITCODE -eq 0 -and $hrHealth -like "*healthy*") { $hrReady = $true }
                    } catch {}
                }
                if ($hrReady) {
                    Log "Container healthy."

                    # Fix 2: set proxy immediately upon confirmed container health
                    $env:ANTHROPIC_BASE_URL = "http://localhost:8000"
                    [Environment]::SetEnvironmentVariable("ANTHROPIC_BASE_URL", "http://localhost:8000", "User")
                    Log "ANTHROPIC_BASE_URL set: http://localhost:8000 (User scope, permanent)"
                    Write-Host ""
                    Write-Host "  Claude Code will now route API calls through the headroom proxy." -ForegroundColor DarkCyan
                    Write-Host "  Proxy URL : http://localhost:8000" -ForegroundColor DarkCyan
                    Write-Host ""
                    Write-Host "  To remove the headroom proxy from Claude Code, run:" -ForegroundColor Gray
                    Write-Host '    $env:ANTHROPIC_BASE_URL = $null' -ForegroundColor DarkCyan
                    Write-Host '    [Environment]::SetEnvironmentVariable("ANTHROPIC_BASE_URL", $null, "User")' -ForegroundColor DarkCyan
                }
                else { Warn "Health check timed out -- rtk install may still work." }

                # Install rtk (Rust Token Killer) binary inside container
                # rtk compresses CLI output (tests, git diff, logs) before it enters the LLM context window
                Info "Installing rtk binary inside container ..."
                $rtkOut = docker exec headroom python -c "from headroom.rtk.installer import download_rtk; p = download_rtk(); print(p)" 2>&1
                if ($LASTEXITCODE -eq 0) { Log "rtk installed: $rtkOut" }
                else { Warn "rtk binary install failed: $rtkOut" }

                # Register rtk as a PreToolUse hook in Claude Code settings (~/.claude/settings.json)
                Info "Registering rtk hooks in Claude Code ..."
                $hooksOut = docker exec headroom python -c "from headroom.rtk.installer import register_claude_hooks; ok = register_claude_hooks(); print(ok)" 2>&1
                if ($LASTEXITCODE -eq 0) { Log "rtk hooks registered: $hooksOut" }
                else { Warn "rtk hook registration failed: $hooksOut" }
            } else {
                Warn "docker compose exited with code $dockerExit -- check Docker logs."
            }
        } catch {
            Warn "Failed to start headroom container: $($_.Exception.Message)"
        } finally {
            Remove-Item -Recurse -Force $headroomTmp -ErrorAction SilentlyContinue
        }
    } else {
        Warn "Docker is installed but not running (daemon offline)."
        Warn "Start Docker Desktop, then run manually:"
        Write-Host "    docker run -d -p 8000:8787 -e HEADROOM_CODE_AWARE_ENABLED=1 ghcr.io/chopratejas/headroom:latest" -ForegroundColor DarkGray
    }
} else {
    Warn "Docker not found -- headroom container skipped."
    Warn "Install Docker Desktop: https://www.docker.com/products/docker-desktop"
}

# -- 10f. ANTHROPIC_BASE_URL config for headroom proxy -----
Head "10f  headroom proxy - Configure ANTHROPIC_BASE_URL"

$headroomUrl = "http://localhost:8000"
$envVarName  = "ANTHROPIC_BASE_URL"

# Live health check before touching any env var
Info "Checking headroom proxy at $headroomUrl/livez ..."
$proxyHealthy = $false
try {
    $resp = Invoke-WebRequest -Uri "$headroomUrl/livez" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    if ($resp.StatusCode -eq 200 -and $resp.Content -like "*healthy*") { $proxyHealthy = $true }
} catch {}

# Fallback to curl.exe (avoids PS proxy/TLS edge cases)
if (-not $proxyHealthy -and (Has "curl.exe")) {
    $curlCode = curl.exe -s -o NUL -w "%{http_code}" --max-time 5 "$headroomUrl/livez" 2>$null
    if ($curlCode -eq "200") { $proxyHealthy = $true }
}

if ($proxyHealthy) {
    $currentValue = [Environment]::GetEnvironmentVariable($envVarName, "User")

    $env:ANTHROPIC_BASE_URL = $headroomUrl
    Info "Set for current session: $envVarName = $headroomUrl"

    if ($currentValue -ne $headroomUrl) {
        [Environment]::SetEnvironmentVariable($envVarName, $headroomUrl, "User")
        Log "Saved permanently (User scope): $envVarName = $headroomUrl"
    } else {
        Log "$envVarName already set correctly."
    }

    Write-Host ""
    Write-Host "  Claude Code will now route through headroom proxy at $headroomUrl" -ForegroundColor DarkCyan
    Write-Host "  To disable: [Environment]::SetEnvironmentVariable('ANTHROPIC_BASE_URL', `$null, 'User')" -ForegroundColor DarkGray
    Write-Host "  To verify : `$env:ANTHROPIC_BASE_URL" -ForegroundColor DarkGray
} else {
    Warn "Proxy not reachable at $headroomUrl -- ANTHROPIC_BASE_URL not set."
    Write-Host "  Start the container first, then set manually:" -ForegroundColor DarkGray
    Write-Host "    `$env:ANTHROPIC_BASE_URL = '$headroomUrl'" -ForegroundColor DarkCyan
    Write-Host "    [Environment]::SetEnvironmentVariable('ANTHROPIC_BASE_URL', '$headroomUrl', 'User')" -ForegroundColor DarkCyan
}

# -- 10g. Auto-start on Windows login ----------------------
# The -StartServer block at the top of this script IS the startup logic.
# Task Scheduler calls: powershell -File "this_script.ps1" -StartServer
# No separate file is created -- the install script is self-contained.
#
# Fixed bugs vs original approach:
#   BUG 1: "cmd.exe /c wrapper.cmd > log 2>&1" in Run key -- redirection
#           stripped by Registry runner, crashes silently.
#   BUG 2: agentmemory TUI needs an Enter keystroke; Run key has no terminal.
#   BUG 3: Run key fires before Node/network are ready (no logon delay).
Write-Host ""
$doAutoStart = $AutoStart -or $SkipPrompts
if (-not $doAutoStart) {
    Write-Host "  Set up agentmemory to auto-start when Windows starts?" -ForegroundColor White
    Write-Host "  Method: Task Scheduler at logon + 1 min delay (no Admin required)." -ForegroundColor DarkGray
    Write-Host "  Tip   : re-run with -AutoStart to skip this prompt next time." -ForegroundColor DarkGray
    Write-Host ""
    $doAutoStart = ((Read-Host "  Auto-start? (Y/N)").Trim().ToUpper() -eq "Y")
}

if ($doAutoStart) {
    # This script is its own startup runner via -StartServer
    $thisScript = $MyInvocation.MyCommand.Path
    if (-not $thisScript) {
        Warn "Cannot resolve script path (\$MyInvocation.MyCommand.Path is empty)."
        Warn "Save this script to a permanent location and re-run -AutoStart from there."
    } else {
        $taskName = "agentmemory_autostart"
        $taskArgs = "-WindowStyle Hidden -NonInteractive -ExecutionPolicy Bypass -File `"$thisScript`" -StartServer"

        # Use Register-ScheduledTask (no admin required for current-user tasks)
        $registered = $false
        try {
            $trigger          = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
            $trigger.Delay    = "PT1M"   # 1-minute delay after logon
            $action           = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $taskArgs
            $settings         = New-ScheduledTaskSettingsSet `
                                    -ExecutionTimeLimit (New-TimeSpan -Hours 0) `
                                    -MultipleInstances IgnoreNew `
                                    -StartWhenAvailable
            Register-ScheduledTask -TaskName $taskName `
                -Trigger $trigger -Action $action -Settings $settings `
                -Force -ErrorAction Stop | Out-Null
            $registered = $true
            Log "Task Scheduler task registered: $taskName"
            Write-Host "  Script: $thisScript -StartServer" -ForegroundColor DarkGray
            Write-Host "  Delay : 1 minute after logon" -ForegroundColor DarkGray
            Write-Host "  Log   : $agentLog" -ForegroundColor DarkGray
            Write-Host "  Remove: Unregister-ScheduledTask -TaskName '$taskName' -Confirm:`$false" -ForegroundColor DarkGray
        } catch {
            Warn "Register-ScheduledTask failed: $($_.Exception.Message)"
        }

        if (-not $registered) {
            # Fallback: Registry Run key (no admin required, no delay)
            Warn "Falling back to Registry Run key."
            $regPath  = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
            $regName  = "agentmemory"
            $regValue = "powershell.exe -WindowStyle Hidden -NonInteractive -ExecutionPolicy Bypass -File `"$thisScript`" -StartServer"
            try {
                Set-ItemProperty -Path $regPath -Name $regName -Value $regValue
                Log "Registry Run key registered (fallback)."
                Write-Host "  Key   : HKCU\...\CurrentVersion\Run\agentmemory" -ForegroundColor DarkGray
                Write-Host "  Remove: Remove-ItemProperty -Path '$regPath' -Name '$regName'" -ForegroundColor DarkGray
            } catch {
                Warn "Failed to set registry key: $($_.Exception.Message)"
            }
        }
    }
} else {
    Info "Skipped. Start manually when needed: & `"$agentWrapper`""
}

# -- Final summary -----------------------------------------
Write-Host ""
Write-Host "============================================" -ForegroundColor White
Write-Host "  All done!" -ForegroundColor Green
Write-Host ""
Write-Host "  Skills    : $globalSkillsDir" -ForegroundColor Gray
Write-Host "  iii.exe   : $iiiExe" -ForegroundColor Gray
Write-Host "  Wrapper   : $agentWrapper" -ForegroundColor Gray
Write-Host "  Log       : $agentLog" -ForegroundColor Gray
Write-Host "  Proxy     : $env:ANTHROPIC_BASE_URL" -ForegroundColor Gray

# Python summary (step 8)
if ($pyType -and $pyType -ne "skip" -and $pyFull) {
    Write-Host ""
    Write-Host "  Python ($pyType):" -ForegroundColor Gray
    if ($pyType -eq "embedded" -and $pyEmbedDir) {
        Write-Host "    Version : Python $pyFull" -ForegroundColor DarkCyan
        Write-Host "    Location: $pyEmbedDir" -ForegroundColor DarkCyan
        $pyPipVer = & (Join-Path $pyEmbedDir "python.exe") -m pip --version 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    pip     : $pyPipVer" -ForegroundColor DarkCyan
        } else {
            Write-Host "    pip     : not installed" -ForegroundColor Yellow
        }
        $pyInPath = $env:PATH -like "*$pyEmbedDir*"
        Write-Host ("    PATH    : " + $(if ($pyInPath) { "added" } else { "not added" })) -ForegroundColor $(if ($pyInPath) { "DarkCyan" } else { "DarkGray" })
        Write-Host "    RTK     : $pyEmbedDir\Scripts\rtk (via pip)" -ForegroundColor DarkGray
    } elseif ($pyType -eq "installer") {
        Write-Host "    Version : Python $pyFull (system installer)" -ForegroundColor DarkCyan
        Write-Host "    Verify  : python --version" -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "  Restart PowerShell if any command is not recognized." -ForegroundColor DarkGray
Write-Host "============================================" -ForegroundColor White
