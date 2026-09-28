$arguments = @($args)
if ($arguments.Count -ge 4 -and $arguments[0] -eq "api" -and $arguments[1] -eq "session.create") {
    $payload = $arguments[3] | ConvertFrom-Json
    @{
        data = @{
            id = "ses_windows_test"
            model = $payload.model
            location = $payload.location
        }
    } | ConvertTo-Json -Compress -Depth 5
    exit 0
}
if ($arguments.Count -ge 2 -and $arguments[0] -eq "--session") {
    Write-Output ("FAKE_TUI " + ($arguments -join " "))
    exit 0
}
if ($arguments -contains "--version") {
    Write-Output "opencode v2.test"
    exit 0
}
exit 1
