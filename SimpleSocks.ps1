function SimpleSocks{
    param(
        [int]$ListenPort = 1080,
        [int]$BufferSize = 32768,
        [int]$MaxConcurrent = 256
    )

    function Read-Exact {
        param(
            [Parameter(Mandatory=$true)]
            [System.IO.Stream]$Stream,

            [Parameter(Mandatory=$true)]
            [byte[]]$Buffer,

            [Parameter(Mandatory=$true)]
            [int]$Offset,

            [Parameter(Mandatory=$true)]
            [int]$Count
        )

        if ($Count -lt 0 -or $Offset -lt 0 -or ($Offset + $Count) -gt $Buffer.Length) {
            throw "Invalid read parameters"
        }

        $total = 0
        while ($total -lt $Count) {
            $read = $Stream.Read($Buffer, $Offset + $total, $Count - $total)
            if ($read -le 0) {
                throw "Stream closed unexpectedly"
            }
            $total += $read
        }
    }

    function Read-Byte {
        param(
            [Parameter(Mandatory=$true)]
            [System.IO.Stream]$Stream
        )

        $b = New-Object byte[] 1
        $read = $Stream.Read($b, 0, 1)
        if ($read -le 0) {
            throw "Stream closed"
        }
        return [int]$b[0]
    }

    function Relay-Sockets {
        param(
            [Parameter(Mandatory=$true)]
            [System.Net.Sockets.TcpClient]$Client,

            [Parameter(Mandatory=$true)]
            [System.Net.Sockets.TcpClient]$Target,

            [Parameter(Mandatory=$true)]
            [int]$BufferSize
        )

        $socketA = $Client.Client
        $socketB = $Target.Client

        $buffer = New-Object byte[] $BufferSize

        try {
            while ($socketA -and $socketB -and ($socketA.Connected -or $socketB.Connected)) {
                # Build list of sockets to poll
                $readList = New-Object 'System.Collections.Generic.List[System.Net.Sockets.Socket]'
                if ($socketA.Connected) { [void]$readList.Add($socketA) }
                if ($socketB.Connected) { [void]$readList.Add($socketB) }

                if ($readList.Count -eq 0) { break }

                $r = New-Object System.Collections.ArrayList
                foreach ($s in $readList) { [void]$r.Add($s) }

                # Wait up to 1s for activity
                [System.Net.Sockets.Socket]::Select($r, $null, $null, 1000000)

                foreach ($s in $r) {
                    if ($s -eq $socketA) {
                        $read = $socketA.Receive($buffer)
                        if ($read -le 0) {
                            try { $socketA.Shutdown([System.Net.Sockets.SocketShutdown]::Both) } catch {}
                            try { $socketA.Close() } catch {}
                        } else {
                            try {
                                [void]$socketB.Send($buffer, 0, $read, [System.Net.Sockets.SocketFlags]::None)
                            } catch {}
                        }
                    }
                    elseif ($s -eq $socketB) {
                        $read = $socketB.Receive($buffer)
                        if ($read -le 0) {
                            try { $socketB.Shutdown([System.Net.Sockets.SocketShutdown]::Both) } catch {}
                            try { $socketB.Close() } catch {}
                        } else {
                            try {
                                [void]$socketA.Send($buffer, 0, $read, [System.Net.Sockets.SocketFlags]::None)
                            } catch {}
                        }
                    }
                }
            }
        }
        catch {
            # swallow, caller handles close/log
        }
    }

    function Handle-Client {
        param(
            [Parameter(Mandatory=$true)]
            [System.Net.Sockets.TcpClient]$Client,

            [Parameter(Mandatory=$true)]
            [int]$BufferSize
        )

        $stream       = $null
        $target       = $null
        $targetStream = $null

        try {
            $Client.NoDelay = $true
            $stream = $Client.GetStream()
            Write-Host "[*] New client: $($Client.Client.RemoteEndPoint)"

            # ---------- GREETING ----------
            $greeting = New-Object byte[] 3
            Read-Exact -Stream $stream -Buffer $greeting -Offset 0 -Count 2

            if ($greeting[0] -ne 5) {
                throw "Not SOCKS5"
            }

            $nmethods = [int]$greeting[1]
            if ($nmethods -lt 0 -or $nmethods -gt 255) {
                throw "Invalid NMETHODS"
            }

            if ($nmethods -gt 0) {
                $methods = New-Object byte[] $nmethods
                Read-Exact -Stream $stream -Buffer $methods -Offset 0 -Count $nmethods
            }

            # Respond: version 5, no auth (method 0)
            $reply = [byte[]](5,0)
            $stream.Write($reply, 0, $reply.Length)

            # ---------- REQUEST ----------
            $request = New-Object byte[] 4
            Read-Exact -Stream $stream -Buffer $request -Offset 0 -Count 4

            if ($request[0] -ne 5 -or $request[1] -ne 1) {
                throw "Bad request (only CONNECT supported)"
            }

            $atyp = [int]$request[3]
            $dest = ""
            $port = 0

            if ($atyp -eq 1) {
                # IPv4
                $ip = New-Object byte[] 4
                Read-Exact -Stream $stream -Buffer $ip -Offset 0 -Count 4
                $dest = ($ip | ForEach-Object { [int]$_ }) -join '.'
            }
            elseif ($atyp -eq 3) {
                # Domain name
                $len = Read-Byte -Stream $stream
                if ($len -lt 1 -or $len -gt 255) {
                    throw "Invalid domain length"
                }
                $name = New-Object byte[] $len
                Read-Exact -Stream $stream -Buffer $name -Offset 0 -Count $len
                $dest = [System.Text.Encoding]::ASCII.GetString($name)
            }
            else {
                throw "Unsupported ATYP"
            }

            $p1 = Read-Byte -Stream $stream
            $p2 = Read-Byte -Stream $stream
            if ($p1 -lt 0 -or $p2 -lt 0) {
                throw "Invalid port"
            }
            $port = ($p1 -shl 8) -bor $p2

            Write-Host "[>] CONNECT $dest : $port"

            # ---------- TARGET CONNECT ----------
            $target = New-Object System.Net.Sockets.TcpClient
            $target.NoDelay = $true
            $target.Connect($dest, $port)
            $targetStream = $target.GetStream()

            # ---------- SUCCESS REPLY ----------
            $success = [byte[]](5,0,0,1,0,0,0,0,0,0)
            $stream.Write($success, 0, $success.Length)
            Write-Host "[+] Relaying..."

            # ---------- RELAY ----------
            Relay-Sockets -Client $Client -Target $target -BufferSize $BufferSize

            #Write-Host "[*] Relay complete"
        }
        catch {
            Write-Host "[ERR] $($_.Exception.Message)"
        }
        finally {
            try { if ($targetStream) { $targetStream.Close() } } catch {}
            try { if ($target)       { $target.Close() } } catch {}
            try { if ($stream)       { $stream.Close() } } catch {}
            try { if ($Client)       { $Client.Close() } } catch {}
        }
    }

    # Create runspace pool and start listeners

    # Seed functions into runspace pool so each client can run in its own thread
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    foreach ($fnName in 'Read-Exact','Read-Byte','Relay-Sockets','Handle-Client') {
        $func  = Get-Item "function:$fnName"
        $entry = New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry($func.Name, $func.Definition)
        $iss.Commands.Add($entry)
    }

    # allow many concurrent clients; 1..$MaxConcurrent runspaces
    $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $MaxConcurrent, $iss, $Host)
    $pool.Open()

    # Create IPv4 and IPv6 listeners
    $ipv4 = $null
    $ipv6 = $null

    try {
        $ipv4 = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $ListenPort)
        $ipv4.Start()
    }
    catch {
        Write-Host "[FATAL] Failed to bind IPv4 loopback on port $ListenPort : $($_.Exception.Message)"
		$ipv4 = $null
    }

    try {
        $ipv6 = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::IPv6Loopback, $ListenPort)
        $ipv6.Start()
    }
    catch {
        Write-Host "[WARN] Failed to bind IPv6 loopback on port $ListenPort : $($_.Exception.Message)"
		$ipv6 = $null
    }

    if (-not $ipv4 -and -not $ipv6) {
        Write-Host "[FATAL] No listeners started. Exiting."
		try { if ($pool) { $pool.Close(); $pool.Dispose() } } catch {}
        return
    }

    Write-Host "[INFO] Listening on:"
    if ($ipv4) { Write-Host "    127.0.0.1:$ListenPort" }
    if ($ipv6) { Write-Host "    [::1]:$ListenPort" }

    Write-Host "[INFO] Press Ctrl+C to stop."

    try{
		# Accept loop
		while ($true) {
			foreach ($listener in @($ipv4, $ipv6)) {
				if (-not $listener) { continue }

				# drain all pending connections for this listener before sleeping
				while ($listener.Pending()) {
					try {
						$client = $listener.AcceptTcpClient()
					}
					catch {
						Write-Host "[WARN] Accept failed: $($_.Exception.Message)"
						break
					}

					# Spawn client handler in the runspace pool
					$ps = [PowerShell]::Create()
					$ps.RunspacePool = $pool
					$null = $ps.AddCommand('Handle-Client').
								 AddParameter('Client', $client).
								 AddParameter('BufferSize', $BufferSize)

					# fire and forget
					$null = $ps.BeginInvoke()
				}
			}
			Start-Sleep -Milliseconds 5
		}
	}
	
	finally {
		Write-Host "[INFO] Stopping listeners..."
		try { if ($ipv4) { $ipv4.Stop() } } catch {}
		try { if ($ipv6) { $ipv6.Stop() } } catch {}
		try { if ($pool) { $pool.Close(); $pool.Dispose() } } catch {}
		Write-Host "[INFO] Stopped."
	}
}
 

