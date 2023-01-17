if(Test-Path -Path "_out") {
    Get-ChildItem -Path "_out" | Remove-Item
}

& dotnet pack "./src/PrecisionScheduler.csproj" -c "Release" -o _out