# Music signaling backend

The backend source is now maintained in `music/backend`. It does not depend on the sibling webtrc frontend directory. Existing binaries copied from the older project are ignored by Git and must be rebuilt; the running production service is not updated automatically.

## Build and run

```powershell
Set-Location 'C:\phpwork\music\backend'
go test ./...
go build -o music-signaling.exe .
.\music-signaling.exe -port 8080
```

Route `wss://music.webtrc.eu.cc/ws` through your TLS reverse proxy to this service's `/ws` on port 8080. Restart the deployed service with the new binary after updating. No additional signaling server or cloud file storage is required.

## Local IP-region lookup

Provide a licensed GeoLite2 City/Country or compatible MaxMind MMDB database yourself. Database provisioning and updates are not automatic. Do not use the small MaxMind test fixture as a production database.

```powershell
.\music-signaling.exe -port 8080 -geoip-db 'C:\GeoIP\GeoLite2-City.mmdb' -trusted-proxies '127.0.0.1/32,::1/128'
```

Alternatively set `GEOIP_DB_PATH` and `TRUSTED_PROXY_CIDRS`. No user IP is sent to a lookup service. Only country/subdivision/city names are broadcast, not the IP address; this is approximate location, not GPS.

The default trusts no proxy headers. Configure only your actual reverse proxies' CIDRs. nginx must overwrite `X-Forwarded-For` with the verified client address or append it to a correctly managed proxy chain. With an additional upstream proxy, its verified client-IP configuration and trusted network ranges must be maintained too. Never trust arbitrary headers or `0.0.0.0/0`.

Without a database, startup logs a warning and displays "地区未知". A configured but unreadable database fails startup explicitly. Lookup failures are logged and display unknown. Private/loopback and unmatched IPs also show unknown.

## Protocol

Existing `publish`, `unpublish`, `signal` and `plaza` messages remain available for compatible clients. The App no longer manually publishes arbitrary files.

```json
{
  "type": "listening",
  "listening": {
    "ownerName": "visitor",
    "title": "Song",
    "artist": "Artist",
    "isPlaying": true,
    "file": { "id": "uuid", "name": "song.mp3", "size": 12345 }
  }
}
```

The optional file is the currently shared song. The server assigns `clientId`, `region`, `file.ownerId` and `file.ownerName`, and sends `listeners` snapshots plus compatible `plaza` file snapshots. The same file stays available on pause; a different file replaces the previous automatic share. Send `{"type":"listening"}` to withdraw both. Missing file metadata allows a status-only user to appear but not be downloaded.

Refresh every 30 seconds; status and automatic files expire after 90 seconds, checked every 10 seconds. Disconnect removes them. File bytes still travel through WebRTC, never through this server.

## Tests

Run `go test ./...` and start an isolated service with `go run . -port 18081`. In another terminal:

```powershell
node .\verify-listening.cjs
```

This publishes temporary test metadata (no audio) and checks automatic files, pause, song replacement, withdrawal, region/identity ownership, disconnect/reconnection, snapshots and legacy file signaling. Do not run this against a production plaza.

For a real database lookup test, set `GEOIP_TEST_DB` to the public MaxMind `GeoIP2-City-Test.mmdb` fixture and run `go test -v ./internal/geoip`. Without that fixture, only this fixture-specific test is skipped; proxy and missing-database tests still run.
