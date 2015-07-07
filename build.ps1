param(
    [Parameter(Position = 0, ValueFromPipeline = $true)] 
    [string] $OpenALPRVersion = "2.0.1",
    [ValidateSet("Build")]
    [Parameter(Position = 1, ValueFromPipeline = $true)] 
    [string] $Target = "Build",
    [Parameter(Position = 2, ValueFromPipeline = $true)]
    [ValidateSet("Debug", "Release")]
    [string] $Configuration = "Release",
    [Parameter(Position = 3, ValueFromPipeline = $true)]
    [ValidateSet("Win32", "x64")]
    [string] $Platform = "x64",
    [ValidateSet("v100", "v110", "v120", "v140")]
    [Parameter(Position = 4, ValueFromPipeline = $true)]
    [string] $PlatformToolset = "v120",
    [ValidateSet("Kepler", "Fermi", "Auto", "None")]
    [Parameter(Position = 5, ValueFromPipeline = $true)]
    [string] $CudaGeneration = "None",
    [Parameter(Position = 6, ValueFromPipeline = $true)]
    [string] $Clean = $false
)

# IO
$WorkingDir = Split-Path -parent $MyInvocation.MyCommand.Definition
$OutputDir = Join-Path $WorkingDir "build\artifacts\$OpenALPRVersion\$PlatformToolset\$Configuration\$Platform"
$DistDir = Join-Path $WorkingDir "build\dist\$OpenALPRVersion\$PlatformToolset\$Configuration\$Platform"
$PatchesDir = Join-Path $WorkingDir patches

# IO Dependencies
$OpenALPRDir = Join-Path $WorkingDir ..
$OpenALPROutputDir = Join-Path $OutputDir openalpr

$OpenALPRNetDir = Join-Path $OpenALPRDir src\bindings\csharp\openalpr-net
$OpenALPRNetDirOutputDir = Join-Path $OutputDir openalpr-net

$TesseractDir = Join-Path $WorkingDir tesseract-ocr
$TesseractOutputDir = Join-Path $OutputDir tesseract
$TesseractIncludeDir = Join-Path $TesseractDir include

$OpenCVDir = Join-Path $WorkingDir opencv 	
$OpenCVOutputDir = Join-Path $OutputDir opencv

if($CudaGeneration -ne "None") {
    $OpenCVOutputDir += "_CUDA_$CudaGeneration"
    $DistDir += "_CUDA_$CudaGeneration"
}

# Msbuild
$global:ToolsVersion = $null
$global:VisualStudioVersion = $null
$global:VXXCommonTools = $null
$global:CmakeGenerator = $null

# Dependencies version numbering
$TesseractVersion = "304"
$LeptonicaVersion = "171"
$OpenCVVersion = "248"
$OpenALPRVersionMajorMinorPatch = $OpenALPRVersion -replace '.', ''

# Metrics
$StopWatch = [System.Diagnostics.Stopwatch]

# Miscellaneous
$DebugPrefix = ""
if($Configuration -eq "Debug") {
    $DebugPrefix = "d"
}

$TesseractLibName = "libtesseract$TesseractVersion-static.lib"
if($Configuration -eq "Debug") {
    $TesseractLibName = "libtesseract$TesseractVersion-static-debug.lib"
}
    
$LeptonicaLibName = "liblept{0}.lib" -f $LeptonicaVersion
if($Configuration -eq "Debug") {
    $LeptonicaLibName = "liblept{0}d.lib" -f $LeptonicaVersion
}

$OpenCVLibName = "{0}{1}" -f $OpenCVVersion, $DebugPrefix

###########################################################################################

function Write-Diagnostic 
{
    param(
        [Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
        [string] $Message
    )

    Write-Host
    Write-Host $Message -ForegroundColor Green
    Write-Host
}

function Invoke-BatchFile 
{
    param(
        [Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
        [string]$Path, 
        [Parameter(Position = 1, Mandatory = $true, ValueFromPipeline = $true)]
    [string]$Parameters
    )

    $tempFile = [IO.Path]::GetTempFileName()
    $batFile = [IO.Path]::GetTempFileName() + ".cmd"

    Set-Content -Path $batFile -Value "`"$Path`" $Parameters && set > `"$tempFile`""

    $batFile

    Get-Content $tempFile | Foreach-Object {   
    if ($_ -match "^(.*?)=(.*)$")
    { 
        Set-Content "env:\$($matches[1])" $matches[2]
        }
   }
   Remove-Item $tempFile
}

function Die 
{
    param(
        [Parameter(Position = 0, ValueFromPipeline = $true)]
        [string] $Message
    )

    Write-Host
    Write-Error $Message 
    exit 1

}

function Requires-Cmake {
    if ((Get-Command "cmake.exe" -ErrorAction SilentlyContinue) -eq $null) {
        Die "Missing cmake.exe"
    }
}

function Requires-Msbuild 
{
    if ((Get-Command "msbuild.exe" -ErrorAction SilentlyContinue) -eq $null) {
        Die "Missing msbuild.exe"
    }
}

function Requires-Nuget 
{
    if ((Get-Command "nuget.exe" -ErrorAction SilentlyContinue) -eq $null) {
        Die "Missing nuget.exe"
    }
}

function Start-Process 
{
    param(
        [string] $Filename,
        [string[]] $Arguments
    )
    
    $StartInfo = New-Object System.Diagnostics.ProcessStartInfo
    $StartInfo.FileName = $Filename
    $StartInfo.Arguments = $Arguments

    $StartInfo.EnvironmentVariables.Clear()

    Get-ChildItem -Path env:* | ForEach-Object {
        $StartInfo.EnvironmentVariables.Add($_.Name, $_.Value)
    }

    $StartInfo.UseShellExecute = $false
    $StartInfo.CreateNoWindow = $false

    $Process = New-Object System.Diagnostics.Process
    $Process.StartInfo = $startInfo
    $Process.Start() | Out-Null
    $Process.WaitForExit()

    if($Process.ExitCode -ne 0) {
        Die ("{0} returned a non-zero exit code" -f $Filename)
    }
}

function Set-PlatformToolset 
{
    Write-Diagnostic "PlatformToolset: $PlatformToolset"

    $ToolsVersion = $null
    $VisualStudioVersion = $null
    $VXXCommonTools = $null

    switch -Exact ($PlatformToolset) {
        "v100" {
            $global:ToolsVersion = "4.0"
            $global:VisualStudioVersion = "10.0"
            $global:VXXCommonTools = $env:VS100COMNTOOLS
            $global:CmakeGenerator = "Visual Studio 10 2010"
        }
        "v110" {
            $global:ToolsVersion = "4.0"
            $global:VisualStudioVersion = "11.0"
            $global:VXXCommonTools = $env:VS110COMNTOOLS
            $global:CmakeGenerator = "Visual Studio 11 2012"
        }
        "v120" {
            $global:ToolsVersion = "12.0"
            $global:VisualStudioVersion = "12.0"
            $global:VXXCommonTools = $env:VS120COMNTOOLS
            $global:CmakeGenerator = "Visual Studio 12 2013"
        }
        "v140" {
            $global:ToolsVersion = "14.0"
            $global:VisualStudioVersion = "14.0"
            $global:VXXCommonTools = $env:VS140COMNTOOLS 
            $global:CmakeGenerator = "Visual Studio 14 2015"
        }
    }

    if ($global:VXXCommonTools -eq $null -or (-not (Test-Path($global:VXXCommonTools)))) {
        Die "PlatformToolset $PlatformToolset is not installed."
    }

    $global:VXXCommonTools = Join-Path $global:VXXCommonTools  "..\..\vc"
    if ($global:VXXCommonTools -eq $null -or (-not (Test-Path($global:VXXCommonTools)))) {
        Die "Error unable to find any visual studio environment"
    }
    
    $VCVarsAll = Join-Path $global:VXXCommonTools vcvarsall.bat
    if (-not (Test-Path $VCVarsAll)) {
        Die "Unable to find $VCVarsAll"
    }
        
    if($Platform -eq "x64") {
        $global:CmakeGenerator += " Win64"
    }

    Write-Diagnostic "PlatformToolset: Successfully configured msvs PlatformToolset $PlatformToolset"

}

function Vcxproj-Parse 
{
    param(
        [Parameter(Position = 0, ValueFromPipeline = $true)]
        [string] $Project,
        [Parameter(Position = 1, ValueFromPipeline = $true)]
        [string] $Xpath
    )

    $Content = Get-Content $Project
    $Xml = New-Object System.Xml.XmlDocument
    $Xml.LoadXml($Content)
    
    $NamespaceManager = New-Object System.Xml.XmlNamespaceManager($Xml.NameTable);
    $NamespaceManager.AddNamespace("rs", "http://schemas.microsoft.com/developer/msbuild/2003");

    $Root = $Xml.DocumentElement
    $Nodes = $Root.SelectNodes($Xpath, $NamespaceManager)
    
    $Properties = @{
        Document = $Xml
        Root = $Xml.DocumentElement
        Nodes = $Root.SelectNodes($Xpath, $NamespaceManager)
    }
        
    $Object = New-Object PSObject -Property $Properties  
    return $Object
}

function Vcxproj-Nuke {
    param(
        [Parameter(Position = 0, ValueFromPipeline = $true)]
        [string] $Project,
        [Parameter(Position = 1, ValueFromPipeline = $true)]
        [string] $Xpath
    )

    $VcxProj = Vcxproj-Parse $Project $Xpath
    if($VcxProj.Nodes.Count -gt 0) {
        foreach($Node in $VcxProj.Nodes) {
            $Node.ParentNode.RemoveChild($Node) | Out-Null
        } 
        $VcxProj.Document.Save($Project)
    }
}

function Vcxproj-Set {
    param(
        [Parameter(Position = 0, ValueFromPipeline = $true)]
        [string] $Project,
        [Parameter(Position = 1, ValueFromPipeline = $true)]
        [string] $Xpath,
		 [Parameter(Position = 2, ValueFromPipeline = $true)]
        [string] $Value
    )

    $VcxProj = Vcxproj-Parse $Project $Xpath
    if($VcxProj.Nodes.Count -gt 0) {
        foreach($Node in $VcxProj.Nodes) {
            $Node.set_InnerXML($Value) | Out-Null
        } 
        $VcxProj.Document.Save($Project)
    }
}

function Msbuild 
{
    param(
        [Parameter(Position = 0, ValueFromPipeline = $true)]
        [string] $Project,
        [Parameter(Position = 1, ValueFromPipeline = $true)]
        [string] $OutDir,
        [Parameter(Position = 2, ValueFromPipeline = $true)]
        [string[]] $ExtraArguments
    )
    
    Write-Diagnostic "Msbuild: Project - $Project"
    Write-Diagnostic "Msbuild: OutDir - $OutDir"
    Write-Diagnostic "Msbuild: Matrix - $Configuration, $Platform, $PlatformToolset"
    
    Requires-Msbuild

    $PreferredToolArchitecture = "Win32"
    if($Platform -eq "x64") {
        $PreferredToolArchitecture = "AMD64"
    }

    # Msbuild requires that output directory has a trailing slash (/)
    if(-not $OutDir.EndsWith("/")) {
        $OutDir += "/"
    }
        
    $Arguments = @(
        "$Project",
        "/t:Rebuild",
        "/m", # Parallel build
        "/p:VisualStudioVersion=$VisualStudioVersion",
        "/p:PlatformTarget=$ToolsVersion",
        "/p:PlatformToolset=$PlatformToolset",
        "/p:Platform=$Platform",
        "/p:PreferredToolArchitecture=$PreferredToolArchitecture",
        "/p:OutDir=`"$OutDir`""
    )

    $Arguments += $ExtraArguments
    
    if($Configuration -eq "Release") {
        $Arguments += "/p:RuntimeLibrary=MultiThreaded"
    } else {
        $Arguments += "/p:RuntimeLibrary=MultiThreadedDebug"
    }
    
    Vcxproj-Nuke $Project "/rs:Project/rs:ItemDefinitionGroup/rs:PostBuildEvent"
    Vcxproj-Set $Project  "/rs:Project/@ToolsVersion" $ToolsVersion

    Start-Process "msbuild.exe" $Arguments

}

function Apply-Patch 
{
    param(
        [Parameter(Position = 0, ValueFromPipeline = $true)]
        [string] $Filename,
        [Parameter(Position = 1, ValueFromPipeline = $true)]
        [string] $DestinationDir
    )

    Write-Diagnostic "Applying patch: $Filename"

    $PatchAbsPath = Join-Path $PatchesDir $Filename

    if(-not (Test-Path $PatchAbsPath)) {
        Write-Output "Patch $Filename already applied, skipping."
        return
    }

    Copy-Item -Force $PatchAbsPath $DestinationDir | Out-Null
    pushd $DestinationDir 
    git reset --hard | Out-Null
    git apply --ignore-whitespace --index $Filename | Out-Null
    pushd $WorkingDir

}

function Set-AssemblyVersion {
    param(
        [parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
        [string]$assemblyInfo,
        [parameter(Position = 1, Mandatory = $true, ValueFromPipeline = $true)]
        [string]$version
    )

    function Write-VersionAssemblyInfo {
        Param(
            [string]
            $version, 

            [string]
            $assemblyInfo
        )

        $nugetVersion = $version
        $version = $version -match "\d+\.\d+\.\d+"
        $version = $matches[0]

        $numberOfReplacements = 0
        $newContent = [System.IO.File]::ReadLines($assemblyInfo) | ForEach-Object {
            $line = $_
            
            if($line.StartsWith("[assembly: AssemblyInformationalVersionAttribute")) {
                $line = "[assembly: AssemblyInformationalVersionAttribute(""$nugetVersion"")]"
                $numberOfReplacements++
            } elseif($line.StartsWith("[assembly: AssemblyFileVersionAttribute")) {
                $line = "[assembly: AssemblyFileVersionAttribute(""$version"")]"
                $numberOfReplacements++
            } elseif($line.StartsWith("[assembly: AssemblyVersionAttribute")) {
                $line = "[assembly: AssemblyVersionAttribute(""$version"")]"
                $numberOfReplacements++
            }
            
            $line		
        } 

        if ($numberOfReplacements -ne 3) {
            Die "Expected to replace the version number in 3 places in AssemblyInfo.cs (AssemblyInformationalVersionAttribute, AssemblyFileVersionAttribute, AssemblyVersionAttribute) but actually replaced it in $numberOfReplacements"
        }

        $newContent | Set-Content $assemblyInfo -Encoding UTF8
    }

    Write-VersionAssemblyInfo -assemblyInfo $assemblyInfo -version $version
}

###########################################################################################

function Build-Tesseract
{
    
    Write-Diagnostic "Tesseract: $Configuration, $Platform, $PlatformToolset"

    $ProjectsPath = Join-Path $WorkingDir tesseract-ocr\dependencies

    if(Test-Path $OutputDir\tesseract\*tesseract*.lib) {
        Write-Output "Tesseract: Already built, skipping."
        return
    }
    
    Msbuild $ProjectsPath\giflib\giflib.vcxproj $OutputDir\tesseract @(
        "/p:Configuration=$Configuration"
    )
    
    Msbuild $ProjectsPath\libjpeg\jpeg.vcxproj $OutputDir\tesseract @(
        "/p:Configuration=$Configuration"
    )
    
    Msbuild $ProjectsPath\zlib\zlibstat.vcxproj $OutputDir\tesseract @(
        "/p:Configuration=$Configuration"		
    )

    Msbuild $ProjectsPath\libpng\libpng.vcxproj $OutputDir\tesseract @(
        "/p:Configuration=$Configuration"		
    )
    
    Msbuild $ProjectsPath\libtiff\libtiff\libtiff.vcxproj $OutputDir\tesseract @(
        "/p:Configuration=$Configuration"				
    )
    
    Msbuild $ProjectsPath\liblept\leptonica.vcxproj $OutputDir\tesseract @(
        "/p:Configuration=LIB_$Configuration"						
    )
        
    Msbuild $ProjectsPath\liblept\leptonica.vcxproj $OutputDir\tesseract @( 
        "/p:Configuration=DLL_$Configuration",
        "/p:LeptonicaDependenciesDirectory=`"$OutputDir\tesseract`"" # Above dependencies link path
    )
    
    Apply-Patch tesseract.x64.support.diff $WorkingDir\tesseract-ocr\src
    
    Msbuild $Workingdir\tesseract-ocr\src\vs2010\libtesseract\libtesseract.vcxproj $OutputDir\tesseract @(
        "/p:Configuration=LIB_$Configuration" 				
    )
}

function Build-OpenCV 
{

    Write-Diagnostic "OpenCV: $Configuration, $Platform, $PlatformToolset"
    
    Requires-Cmake
    
    if(Test-Path $OpenCVOutputDir) {
        Write-Output "OpenCV: Already built, skipping."
        return
    }

    $CmakeArguments = @(
        "-DBUILD_PERF_TESTS=OFF",
        "-DBUILD_TESTS=OFF",
        "-DBUILD_EXAMPLES=OFF",
        "-DCMAKE_BUILD_TYPE=$Configuration",
        "-Wno-dev",
        "-G`"$global:CmakeGenerator`"",
        "-H`"$OpenCVDir`"",
        "-B`"$OpenCVOutputDir`""
    )
    
    if($CudaGeneration -eq "None") {
        $CmakeArguments += "-DWITH_CUDA=OFF"
    } else {
        $CmakeArguments += "-DCUDA_GENERATION=$CudaGeneration"
    }

    if($CudaGeneration -ne "None") {
        Apply-Patch opencv.248.cudafixes.diff $OpenCVDir\modules\gpu\src\nvidia\core
    }

    Start-Process "cmake.exe" @($CmakeArguments)
    
    Start-Process "cmake.exe" @(
        "--build `"$OpenCVOutputDir`" --config $Configuration"
    )
    
}

function Build-OpenALPR 
{
    Write-Diagnostic "OpenALPR: $Configuration, $Platform, $PlatformToolset"

    Requires-Cmake
    
    if(Test-Path $OpenALPROutputDir) {
        Write-Output "OpenALPR: Already built, skipping."
        return
    }
        
    $OpenALPR_WITH_GPU_DETECTOR = "OFF"
    if($CudaGeneration -ne "None") {
        $OpenALPR_WITH_GPU_DETECTOR = "ON"
    }
    
    $CmakeArguments = @(
        "-DTesseract_INCLUDE_BASEAPI_DIR=$TesseractIncludeDir",
        "-DTesseract_INCLUDE_CCMAIN_DIR=$TesseractDir\src\ccmain",
        "-DTesseract_INCLUDE_CCSTRUCT_DIR=$TesseractDir\src\ccstruct",
        "-DTesseract_INCLUDE_CCUTIL_DIR=$TesseractDir\src\ccutil",
        "-DTesseract_LIB=$TesseractOutputDir\$TesseractLibName",
        "-DLeptonica_LIB=$TesseractOutputDir\$LeptonicaLibName",
        "-DOpenCV_DIR=$OpenCVOutputDir",
        "-DOPENALPR_MAJOR_VERSION=$OpenALPRVersionMajorMinorPatch[0]",
        "-DOPENALPR_MINOR_VERSION=$OpenALPRVersionMajorMinorPatch[1]",
        "-DOPENALPR_PATCH_VERSION=$OpenALPRVersionMajorMinorPatch[2]",
        "-DOPENALPR_VERSION=$OpenALPRVersionMajorMinorPatch",
        "-DWITH_GPU_DETECTOR=$OpenALPR_WITH_GPU_DETECTOR",
        "-DWITH_TESTS=OFF",
        "-DWITH_BINDING_JAVA=OFF",
        "-DWITH_BINDING_PYTHON=OFF",
        "-DWITH_UTILITIES=ON",
        "-DCMAKE_BUILD_TYPE=$Configuration",
        "-Wno-dev",
        "-G`"$global:CmakeGenerator`"",
        "-H`"$OpenALPRDir\src`"",
        "-B`"$OpenALPROutputDir`""
    )
    
    Start-Process "cmake.exe" @($CmakeArguments)
    
    Start-Process "cmake.exe" @(
        "--build `"$OpenALPROutputDir`" --config $Configuration"
    )	

    Copy-Build-Result-To $DistDir
}

function Build-OpenALPRNet 
{
    Write-Diagnostic "OpenALPRNet: $Configuration, $Platform, $PlatformToolset"

    if(Test-Path $OpenALPRNetDirOutputDir) {
        Write-Output "OpenALPRNet: Already built, skipping."
        return
    }

    $VcxProjectFilename = Join-Path $OpenALPRNetDirOutputDir openalpr-net.vcxproj

    function Copy-Sources
    {		
        Copy-Item $OpenALPRNetDir -Recurse -Force $OpenALPRNetDirOutputDir | Out-Null

        $AdditionalIncludeDirectories = @(
            "$OpenALPRDir\src\openalpr",
            "$TesseractDir\tesseract-ocr\src\api",
            "$TesseractDir\tesseract-ocr\src\ccstruct",
            "$TesseractDir\tesseract-ocr\src\ccmain",
            "$TesseractDir\tesseract-ocr\src\ccutil",
            "$OpenCVDir\opencv\include",
            "$OpenCVDir\opencv\include\opencv",
            "$OpenCVDir\modules\core\include",
            "$OpenCVDir\modules\flann\include",
            "$OpenCVDir\modules\imgproc\include",
            "$OpenCVDir\modules\highgui\include",
            "$OpenCVDir\modules\features2d\include",
            "$OpenCVDir\modules\calib3d\include",
            "$OpenCVDir\modules\ml\include",
            "$OpenCVDir\modules\video\include",
            "$OpenCVDir\modules\legacy\include",
            "$OpenCVDir\modules\objdetect\include",
            "$OpenCVDir\modules\photo\includ;",
            "$OpenCVDir\modules\gpu\include",
            "$OpenCVDir\modules\ocl\include",
            "$OpenCVDir\modules\nonfree\include",
            "$OpenCVDir\modules\contrib\include",
            "$OpenCVDir\modules\stitching\include",
            "$OpenCVDir\modules\superres\include",
            "$OpenCVDir\modules\ts\include",
            "$OpenCVDir\modules\videostab\include"
        ) 

        $AdditionalDependencies = @(
            'kernel32.lib',
            'user32.lib',
            'gdi32.lib',
            'winspool.lib',
            'shell32.lib',
            'ole32.lib',
            'oleaut32.lib',
            'uuid.lib',
            'comdlg32.lib',
            'advapi32.lib',
            'ws2_32.lib',
            "$DistDir\opencv_videostab$OpenCVLibName.lib",
            "$DistDir\opencv_ts$OpenCVLibName.lib",
            "$DistDir\opencv_superres$OpenCVLibName.lib",
            "$DistDir\opencv_stitching$OpenCVLibName.lib",
            "$DistDir\opencv_contrib$OpenCVLibName.lib",
            "$DistDir\opencv_nonfree$OpenCVLibName.lib",
            "$DistDir\opencv_ocl$OpenCVLibName.lib",
            "$DistDir\opencv_gpu$OpenCVLibName.lib",
            "$DistDir\opencv_photo$OpenCVLibName.lib",
            "$DistDir\opencv_objdetect$OpenCVLibName.lib",
            "$DistDir\opencv_legacy$OpenCVLibName.lib",
            "$DistDir\opencv_video$OpenCVLibName.lib",
            "$DistDir\opencv_ml$OpenCVLibName.lib",
            "$DistDir\opencv_calib3d$OpenCVLibName.lib",
            "$DistDir\opencv_features2d$OpenCVLibName.lib",
            "$DistDir\opencv_highgui$OpenCVLibName.lib",
            "$DistDir\opencv_imgproc$OpenCVLibName.lib",
            "$DistDir\opencv_flann$OpenCVLibName.lib",
            "$DistDir\opencv_flann$OpenCVLibName.lib",
            "$DistDir\opencv_core$OpenCVLibName.lib",
            "$DistDir\openalpr-static.lib"
            "$DistDir\support.lib"
            "$DistDir\video.lib"
            "$DistDir\$TesseractLibName",
            "$DistDir\$LeptonicaLibName"
        )

        # <AdditionalDependencies>
        Vcxproj-Set $OpenALPRNetDirOutputDir\openalpr-net.vcxproj `
			 "/rs:Project/rs:ItemDefinitionGroup/rs:Link/rs:AdditionalDependencies" `
			 ($AdditionalDependencies -join ";")

        # <AdditionalIncludeDirectories>
		Vcxproj-Set $OpenALPRNetDirOutputDir\openalpr-net.vcxproj `
			"/rs:Project/rs:ItemDefinitionGroup/rs:ClCompile/rs:AdditionalIncludeDirectories" `
			($AdditionalIncludeDirectories -join ";")

        # Nuke <TargetPlatformVersion>
        Vcxproj-Nuke $VcxProjectFilename "/rs:Project/rs:PropertyGroup/rs:TargetPlatformVersion"

        # Set assembly info
        Set-AssemblyVersion $OpenALPRNetDirOutputDir\AssemblyInfo.cpp $OpenALPRVersion
    }

    function Build-Sources
    {
        Msbuild $VcxProjectFilename $OpenALPRNetDirOutputDir\$Configuration @(
            "/p:Configuration=$Configuration",
            "/p:TargetFrameworkVersion=v4.0"
        )

        Copy-Item -Force $OpenALPRNetDirOutputDir\$Configuration\openalpr-net.dll $DistDir | Out-Null
    }

    function Nupkg 
    {		
        Requires-Nuget

        $NuspecFile = Join-Path $WorkingDir openalpr.nuspec

        $NupkgProperties = @(
            "DistDir=`"$DistDir`"",
            "Platform=`"$Platform`"",
            "PlatformToolset=`"$PlatformToolset`"",
            "Version=$OpenALPRVersion",
            "Configuration=$Configuration"
        ) -join ";"

        $NupkgArguments = @(
            "pack",
            "$NuspecFile",
            "-Properties `"$NupkgProperties`"",
            "-OutputDirectory `"$DistDir`""
        )

        Start-Process "nuget.exe" $NupkgArguments
    }
    
    Copy-Sources
    Build-Sources
    Nupkg

}

function Copy-Build-Result-To
{
    param(
        [Parameter(Position = 0, ValueFromPipeline = $true)]
        [string] $DestinationDir
    )
    
    Write-Diagnostic "Copy: $DestinationDir"
    
    if(-not (Test-Path($DestinationDir))) {
        New-Item -ItemType Directory -Path $DestinationDir -Force | Out-Null
    }

    # OpenCV
    Copy-Item (Join-Path $OpenCVOutputDir bin\$Configuration\*.dll) $DestinationDir | Out-Null
    Copy-Item (Join-Path $OpenCVOutputDir lib\$Configuration\*.lib) $DestinationDir | Out-Null

    # Tesseract
    Copy-Item $TesseractOutputDir\*.dll -Force $DestinationDir | Out-Null
    Copy-Item $TesseractOutputDir\*.lib -Force $DestinationDir | Out-Null

    # OpenALPR
    Copy-Item $OutputDir\openalpr\$Configuration\alpr.exe $DestinationDir | Out-Null	
    Copy-Item $OutputDir\openalpr\misc_utilities\$Configuration\*.* $DestinationDir | Out-Null	
    Copy-Item $OpenALPROutputDir\openalpr\$Configuration\openalpr.lib -Force $DestinationDir\openalpr.lib | Out-Null
    Copy-Item $OpenALPROutputDir\openalpr\$Configuration\openalpr-static.lib -Force $DestinationDir\openalpr-static.lib | Out-Null
    Copy-Item $OpenALPROutputDir\video\$Configuration\video.lib -Force $DestinationDir\video.lib | Out-Null
    Copy-Item $OpenALPROutputDir\openalpr\support\$Configuration\support.lib -Force $DestinationDir\support.lib | Out-Null
    Copy-Item $OpenALPRDir\runtime_data\ -Recurse -Force $DestinationDir\runtime_data\ | Out-Null
    Copy-Item $OpenALPRDir\config\openalpr.conf.in -Force $DestinationDir\openalpr.conf | Out-Null
    (Get-Content $DestinationDir\openalpr.conf) -replace '^runtime_dir.*$', 'runtime_dir = runtime_data' | Out-File $DestinationDir\openalpr.conf -Encoding "ASCII" | Out-Null

}

$BuildTime = $StopWatch::StartNew()

switch($Target) 
{
    "Build" {			
        if($Clean -eq $true) {
            Remove-Item -Recurse -Force $OutputDir | Out-Null 
            Remove-Item -Recurse -Force $DistDir | Out-Null
        }
        Set-PlatformToolset

        Build-Tesseract
        Build-OpenCV
        Build-OpenALPR
        Build-OpenALPRNet
    }
}

$BuildTime.Stop()		
$Elapsed = $BuildTime.Elapsed
Write-Diagnostic "Elapsed: $Elapsed"