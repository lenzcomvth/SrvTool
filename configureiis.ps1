# IIS Configuration Script
# Sử dụng: .\configure_iis.ps1 -IPAddress "192.168.1.100" -Domain "example.com" -WebsitePath "C:\inetpub\wwwroot\mysite" -SiteName "MyWebsite"

param(
    [Parameter(Mandatory=$true)]
    [string]$IPAddress,
    
    [Parameter(Mandatory=$true)]
    [string]$Domain,
    
    [Parameter(Mandatory=$true)]
    [string]$WebsitePath,
    
    [Parameter(Mandatory=$true)]
    [string]$SiteName,
    
    [int]$Port = 80,
    [string]$AppPool = "DefaultAppPool",
    [switch]$RemoveExisting = $true,
    [switch]$AddWWWBinding = $true,
    [switch]$RestartIIS = $true,
    [switch]$SetPermissions = $true,
    [switch]$ShowVerbose = $false
)

# Function để ghi log với màu sắc
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    
    $timestamp = Get-Date -Format "HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    
    switch ($Level) {
        "ERROR" { Write-Host $logMessage -ForegroundColor Red }
        "WARNING" { Write-Host $logMessage -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $logMessage -ForegroundColor Green }
        "INFO" { Write-Host $logMessage -ForegroundColor Cyan }
        default { Write-Host $logMessage -ForegroundColor White }
    }
}

# Function để kiểm tra quyền Administrator
function Test-Administrator {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Function để tự động nâng quyền lên Administrator
function Elevate-Privileges {
    if (!(Test-Administrator)) {
        Write-Log "Script cần quyền Administrator để chạy. Đang nâng quyền..." "WARNING"
        
        try {
            $scriptPath = $MyInvocation.MyCommand.Path
            $arguments = $MyInvocation.BoundParameters.GetEnumerator() | ForEach-Object {
                if ($_.Value -is [switch]) {
                    if ($_.Value) { "-$($_.Key)" }
                } else {
                    "-$($_.Key) `"$($_.Value)`""
                }
            } | Where-Object { $_ } | ForEach-Object { $_ } | Out-String -Width 4096
            
            $processInfo = New-Object System.Diagnostics.ProcessStartInfo
            $processInfo.FileName = "powershell.exe"
            $processInfo.Arguments = "-ExecutionPolicy Bypass -File `"$scriptPath`" $arguments"
            $processInfo.Verb = "runas"
            $processInfo.UseShellExecute = $true
            
            Write-Log "Đang mở PowerShell mới với quyền Administrator..." "INFO"
            $process = [System.Diagnostics.Process]::Start($processInfo)
            
            if ($process) {
                Write-Log "Script đã được mở với quyền Administrator. Đóng PowerShell hiện tại..." "SUCCESS"
                Start-Sleep -Seconds 2
                exit 0
            } else {
                throw "Không thể nâng quyền lên Administrator"
            }
        }
        catch {
            Write-Log "❌ Không thể tự động nâng quyền: $($_.Exception.Message)" "ERROR"
            Write-Log "Vui lòng chạy PowerShell với quyền Administrator (Run as Administrator)" "ERROR"
            exit 1
        }
    }
}

# Function để kiểm tra IIS có được cài đặt không
function Test-IISInstalled {
    try {
        Import-Module WebAdministration -ErrorAction Stop
        Write-Log "✓ WebAdministration module loaded successfully" "SUCCESS"
        return $true
    }
    catch {
        Write-Log "❌ Không thể load WebAdministration module. IIS chưa được cài đặt hoặc không đúng cách." "ERROR"
        Write-Log "Vui lòng cài đặt IIS với các tính năng cần thiết:" "INFO"
        Write-Log "  - Web Server (IIS)" "INFO"
        Write-Log "  - Web Management Tools" "INFO"
        Write-Log "  - Common HTTP Features" "INFO"
        Write-Log "  - Application Development Features" "INFO"
        return $false
    }
}

# Function để kiểm tra và tạo Application Pool
function Test-CreateAppPool {
    param([string]$AppPoolName)
    
    try {
        $existingPool = Get-IISAppPool -Name $AppPoolName -ErrorAction SilentlyContinue
        
        if (!$existingPool) {
            Write-Log "Tạo Application Pool: $AppPoolName"
            New-WebAppPool -Name $AppPoolName
            Write-Log "✓ Application Pool '$AppPoolName' đã được tạo" "SUCCESS"
        } else {
            Write-Log "✓ Application Pool '$AppPoolName' đã tồn tại" "SUCCESS"
        }
        
        # Cấu hình Application Pool
        Set-ItemProperty -Path "IIS:\AppPools\$AppPoolName" -Name "managedRuntimeVersion" -Value "v4.0"
        Set-ItemProperty -Path "IIS:\AppPools\$AppPoolName" -Name "processModel.identityType" -Value "ApplicationPoolIdentity"
        Set-ItemProperty -Path "IIS:\AppPools\$AppPoolName" -Name "processModel.idleTimeout" -Value "00:00:00"
        Set-ItemProperty -Path "IIS:\AppPools\$AppPoolName" -Name "recycling.periodicRestart.time" -Value "00:00:00"
        
        Write-Log "✓ Application Pool '$AppPoolName' đã được cấu hình" "SUCCESS"
        return $true
    }
    catch {
        Write-Log "❌ Lỗi khi tạo/cấu hình Application Pool: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# Function để kiểm tra và tạo thư mục website
function Test-CreateWebsiteDirectory {
    param([string]$PhysicalPath)
    
    try {
        if (!(Test-Path $PhysicalPath)) {
            Write-Log "Tạo thư mục website: $PhysicalPath"
            New-Item -ItemType Directory -Path $PhysicalPath -Force | Out-Null
            Write-Log "✓ Thư mục website đã được tạo" "SUCCESS"
        } else {
            Write-Log "✓ Thư mục website đã tồn tại: $PhysicalPath" "SUCCESS"
        }
        
        # Tạo file index.html mặc định nếu thư mục trống
        $indexFile = Join-Path $PhysicalPath "index.html"
        if (!(Test-Path $indexFile)) {
            $htmlContent = @"
<!DOCTYPE html>
<html>
<head>
    <title>$SiteName</title>
    <meta charset="utf-8">
</head>
<body>
    <h1>Welcome to $SiteName</h1>
    <p>Website đã được cấu hình thành công!</p>
    <p>Domain: $Domain</p>
    <p>IP: $IPAddress</p>
    <p>Port: $Port</p>
    <p>Path: $PhysicalPath</p>
    <p>Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</p>
</body>
</html>
"@
            $htmlContent | Out-File -FilePath $indexFile -Encoding UTF8
            Write-Log "✓ File index.html mặc định đã được tạo" "SUCCESS"
        }
        
        return $true
    }
    catch {
        Write-Log "❌ Lỗi khi tạo thư mục website: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# Function để thiết lập quyền truy cập cho thư mục website
function Set-WebsitePermissions {
    param([string]$PhysicalPath)
    
    try {
        Write-Log "Thiết lập quyền truy cập cho thư mục website..."
        
        # Lấy ACL hiện tại
        $acl = Get-Acl -Path $PhysicalPath
        
        # Thêm quyền cho IIS_IUSRS
        $iisUserRule = New-Object System.Security.AccessControl.FileSystemAccessRule("IIS_IUSRS", "Modify", "ContainerInherit,ObjectInherit", "None", "Allow")
        $acl.SetAccessRule($iisUserRule)
        
        # Thêm quyền cho NETWORK SERVICE
        $networkServiceRule = New-Object System.Security.AccessControl.FileSystemAccessRule("NETWORK SERVICE", "Modify", "ContainerInherit,ObjectInherit", "None", "Allow")
        $acl.SetAccessRule($networkServiceRule)
        
        # Thêm quyền cho Application Pool Identity
        $appPoolRule = New-Object System.Security.AccessControl.FileSystemAccessRule("IIS AppPool\$AppPool", "Modify", "ContainerInherit,ObjectInherit", "None", "Allow")
        $acl.SetAccessRule($appPoolRule)
        
        # Áp dụng ACL
        Set-Acl -Path $PhysicalPath -AclObject $acl
        
        Write-Log "✓ Quyền truy cập đã được thiết lập" "SUCCESS"
        return $true
    }
    catch {
        Write-Log "⚠️ Lỗi khi thiết lập quyền truy cập: $($_.Exception.Message)" "WARNING"
        return $false
    }
}

# Function để xóa website hiện tại
function Remove-ExistingWebsite {
    param([string]$WebsiteName)
    
    try {
        $existingSite = Get-Website -Name $WebsiteName -ErrorAction SilentlyContinue
        
        if ($existingSite) {
            Write-Log "Xóa website hiện tại: $WebsiteName"
            
            # Dừng website trước khi xóa
            if ($existingSite.State -eq "Started") {
                Stop-Website -Name $WebsiteName
                Write-Log "✓ Website đã được dừng" "SUCCESS"
            }
            
            # Xóa website
            Remove-Website -Name $WebsiteName
            Write-Log "✓ Website hiện tại đã được xóa" "SUCCESS"
            return $true
        } else {
            Write-Log "✓ Không có website nào tên '$WebsiteName' để xóa" "SUCCESS"
            return $true
        }
    }
    catch {
        Write-Log "❌ Lỗi khi xóa website: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# Function để tạo website mới
function New-WebsiteWithBindings {
    param(
        [string]$WebsiteName,
        [string]$AppPoolName,
        [string]$PhysicalPath,
        [string]$IPAddress,
        [int]$Port,
        [string]$Domain
    )
    
    try {
        Write-Log "Tạo website mới: $WebsiteName"
        
        # Tạo website
        New-Website -Name $WebsiteName -ApplicationPool $AppPoolName -PhysicalPath $PhysicalPath -Port $Port -IPAddress $IPAddress -ErrorAction Stop
        Write-Log "✓ Website đã được tạo thành công" "SUCCESS"
        
        # Xóa binding mặc định (không có hostname)
        Write-Log "Xóa binding mặc định (không có hostname)..."
        try {
            Remove-WebBinding -Name $WebsiteName -Protocol http -IPAddress $IPAddress -Port $Port -ErrorAction Stop
            Write-Log "✓ Binding mặc định đã được xóa" "SUCCESS"
        }
        catch {
            Write-Log "⚠️ Không thể xóa binding mặc định: $($_.Exception.Message)" "WARNING"
        }
        
        # Thêm host name bindings
        Write-Log "Thêm host name bindings..."
        
        # Binding cho domain.com
        try {
            New-WebBinding -Name $WebsiteName -Protocol http -IPAddress $IPAddress -Port $Port -HostHeader $Domain -ErrorAction Stop
            Write-Log "✓ Domain binding đã được thêm: $Domain" "SUCCESS"
        }
        catch {
            Write-Log "❌ Lỗi khi thêm domain binding: $($_.Exception.Message)" "ERROR"
            return $false
        }
        
        # Binding cho www.domain.com (nếu được yêu cầu)
        if ($AddWWWBinding) {
            try {
                New-WebBinding -Name $WebsiteName -Protocol http -IPAddress $IPAddress -Port $Port -HostHeader "www.$Domain" -ErrorAction Stop
                Write-Log "✓ WWW binding đã được thêm: www.$Domain" "SUCCESS"
            }
            catch {
                Write-Log "❌ Lỗi khi thêm www binding: $($_.Exception.Message)" "ERROR"
                return $false
            }
        }
        
        # Cấu hình website
        Set-ItemProperty -Path "IIS:\Sites\$WebsiteName" -Name "logFile.directory" -Value "C:\inetpub\logs\LogFiles\$WebsiteName"
        Set-ItemProperty -Path "IIS:\Sites\$WebsiteName" -Name "logFile.logFormat" -Value "W3C"
        Set-ItemProperty -Path "IIS:\Sites\$WebsiteName" -Name "logFile.logExtFileFlags" -Value "Date,Time,ClientIP,UserName,SiteName,ComputerName,ServerIP,Method,UriStem,UriQuery,HttpStatus,Win32Status,TimeTaken,ServerPort,UserAgent,Referer,ProtocolVersion,Host,HttpSubStatus"
        
        Write-Log "✓ Website đã được cấu hình hoàn chỉnh" "SUCCESS"
        return $true
    }
    catch {
        Write-Log "❌ Lỗi khi tạo website: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# Function để restart IIS
function Restart-IIS {
    try {
        Write-Log "Restart IIS..."
        
        # Dừng IIS
        Write-Log "Dừng IIS..."
        iisreset /stop
        Start-Sleep -Seconds 3
        
        # Khởi động IIS
        Write-Log "Khởi động IIS..."
        iisreset /start
        
        Write-Log "✓ IIS đã được restart thành công" "SUCCESS"
        return $true
    }
    catch {
        Write-Log "⚠️ Lỗi khi restart IIS: $($_.Exception.Message)" "WARNING"
        return $false
    }
}

# Function để hiển thị thông tin cấu hình
function Show-ConfigurationInfo {
    param(
        [string]$WebsiteName,
        [string]$IPAddress,
        [int]$Port,
        [string]$Domain,
        [string]$PhysicalPath,
        [string]$AppPoolName
    )
    
    Write-Log "=== THÔNG TIN CẤU HÌNH IIS ===" "SUCCESS"
    Write-Log "Website Name: $WebsiteName"
    Write-Log "URL: http://$IPAddress`:$Port"
    Write-Log "Host 1: $Domain`:$Port"
    if ($AddWWWBinding) {
        Write-Log "Host 2: www.$Domain`:$Port"
    }
    Write-Log "Physical Path: $PhysicalPath"
    Write-Log "Application Pool: $AppPoolName"
    Write-Log "Port: $Port"
    Write-Log "IP Address: $IPAddress"
    Write-Log "=============================" "SUCCESS"
}

# Function để kiểm tra website có hoạt động không
function Test-WebsiteStatus {
    param([string]$WebsiteName)
    
    try {
        $website = Get-Website -Name $WebsiteName -ErrorAction SilentlyContinue
        
        if ($website) {
            Write-Log "=== TRẠNG THÁI WEBSITE ===" "INFO"
            Write-Log "Name: $($website.Name)"
            Write-Log "State: $($website.State)"
            Write-Log "Application Pool: $($website.ApplicationPool)"
            Write-Log "Physical Path: $($website.PhysicalPath)"
            Write-Log "Bindings:"
            
            $bindings = Get-WebBinding -Name $WebsiteName
            foreach ($binding in $bindings) {
                Write-Log "  - $($binding.Protocol)://$($binding.BindingInformation)"
            }
            
            Write-Log "=========================" "INFO"
            return $true
        } else {
            Write-Log "❌ Không tìm thấy website: $WebsiteName" "ERROR"
            return $false
        }
    }
    catch {
        Write-Log "❌ Lỗi khi kiểm tra trạng thái website: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# Main execution function
function Main {
    Write-Log "=== IIS CONFIGURATION SCRIPT ===" "SUCCESS"
    Write-Log "IP Address: $IPAddress"
    Write-Log "Domain: $Domain"
    Write-Log "Website Path: $WebsitePath"
    Write-Log "Site Name: $SiteName"
    Write-Log "Port: $Port"
    Write-Log "Application Pool: $AppPool"
    Write-Log "Remove Existing: $RemoveExisting"
    Write-Log "Add WWW Binding: $AddWWWBinding"
    Write-Log "Restart IIS: $RestartIIS"
    Write-Log "Set Permissions: $SetPermissions"
    Write-Log ""
    
    # Tự động nâng quyền nếu cần
    Elevate-Privileges
    
    # Kiểm tra quyền Administrator
    if (!(Test-Administrator)) {
        Write-Log "❌ Script này cần quyền Administrator để chạy!" "ERROR"
        exit 1
    }
    
    Write-Log "✓ Script đang chạy với quyền Administrator" "SUCCESS"
    
    try {
        # Kiểm tra IIS có được cài đặt không
        if (!(Test-IISInstalled)) {
            Write-Log "❌ IIS chưa được cài đặt hoặc không đúng cách" "ERROR"
            exit 1
        }
        
        # Kiểm tra và tạo Application Pool
        if (!(Test-CreateAppPool -AppPoolName $AppPool)) {
            Write-Log "❌ Không thể tạo/cấu hình Application Pool" "ERROR"
            exit 1
        }
        
        # Kiểm tra và tạo thư mục website
        if (!(Test-CreateWebsiteDirectory -PhysicalPath $WebsitePath)) {
            Write-Log "❌ Không thể tạo thư mục website" "ERROR"
            exit 1
        }
        
        # Thiết lập quyền truy cập (nếu được yêu cầu)
        if ($SetPermissions) {
            if (!(Set-WebsitePermissions -PhysicalPath $WebsitePath)) {
                Write-Log "⚠️ Không thể thiết lập quyền truy cập, nhưng vẫn tiếp tục..." "WARNING"
            }
        }
        
        # Xóa website hiện tại (nếu được yêu cầu)
        if ($RemoveExisting) {
            if (!(Remove-ExistingWebsite -WebsiteName $SiteName)) {
                Write-Log "❌ Không thể xóa website hiện tại" "ERROR"
                exit 1
            }
        }
        
        # Tạo website mới với bindings
        if (!(New-WebsiteWithBindings -WebsiteName $SiteName -AppPoolName $AppPool -PhysicalPath $WebsitePath -IPAddress $IPAddress -Port $Port -Domain $Domain)) {
            Write-Log "❌ Không thể tạo website mới" "ERROR"
            exit 1
        }
        
        # Restart IIS (nếu được yêu cầu)
        if ($RestartIIS) {
            if (!(Restart-IIS)) {
                Write-Log "⚠️ Không thể restart IIS, nhưng website đã được tạo" "WARNING"
            }
        }
        
        # Hiển thị thông tin cấu hình
        Show-ConfigurationInfo -WebsiteName $SiteName -IPAddress $IPAddress -Port $Port -Domain $Domain -PhysicalPath $WebsitePath -AppPoolName $AppPool
        
        # Kiểm tra trạng thái website
        Test-WebsiteStatus -WebsiteName $SiteName
        
        Write-Log "=== CẤU HÌNH IIS HOÀN TẤT THÀNH CÔNG! ===" "SUCCESS"
        Write-Log "Website đã sẵn sàng tại: http://$IPAddress`:$Port" "SUCCESS"
        Write-Log "Domain: $Domain" "SUCCESS"
        if ($AddWWWBinding) {
            Write-Log "WWW: www.$Domain" "SUCCESS"
        }
        Write-Log "Bạn có thể truy cập website ngay bây giờ!" "SUCCESS"
    }
    catch {
        Write-Log "❌ Có lỗi xảy ra: $($_.Exception.Message)" "ERROR"
        exit 1
    }
}

# Chạy script
Main 