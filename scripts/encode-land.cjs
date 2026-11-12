// Encodes Natural Earth land polygons for the iOS plaza globe (AURU MUSIC/Views/CandyEarthLand.swift).
//   curl -LO https://cdn.jsdelivr.net/gh/nvkelso/natural-earth-vector@v5.1.2/geojson/ne_110m_land.geojson
//   node scripts/encode-land.cjs ne_110m_land.geojson "AURU MUSIC/Views/CandyEarthLand.swift"
const fs = require('fs')
const g = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'))
const vals = []
let rings = 0, pts = 0
for (const f of g.features) {
  const polys = f.geometry.type === 'Polygon' ? [f.geometry.coordinates] : f.geometry.coordinates
  for (const poly of polys) for (const ring of poly) {
    rings++
    for (const [lon, lat] of ring) { vals.push(Math.round(lon * 100), Math.round(lat * 100)); pts++ }
    vals.push(32767, 32767)
  }
}
const buf = Buffer.alloc(vals.length * 2)
vals.forEach((v, i) => buf.writeInt16LE(v, i * 2))
const b64 = buf.toString('base64')
console.error({ rings, pts, bytes: buf.length, b64: b64.length })
const lines = b64.match(/.{1,120}/g).map((l) => '        "' + l + '"').join(',\n')
fs.writeFileSync(process.argv[3], `import Foundation

// Natural Earth 1:110m land polygons (public domain, naturalearthdata.com), v5.1.2.
// Encoding: little-endian Int16 pairs (longitude × 100, latitude × 100); (32767, 32767) ends a ring.
// Regenerate with scripts/encode-land.cjs.
enum CandyEarthLand {
    static let encoded: [String] = [
${lines}
    ]

    /// Rings of (longitude, latitude) in degrees.
    static let rings: [[(Double, Double)]] = {
        guard let data = Data(base64Encoded: encoded.joined()) else { return [] }
        var rings: [[(Double, Double)]] = []
        var ring: [(Double, Double)] = []
        data.withUnsafeBytes { raw in
            let count = raw.count / 4
            for index in 0..<count {
                let lon = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 4, as: Int16.self))
                let lat = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 4 + 2, as: Int16.self))
                if lon == Int16.max && lat == Int16.max {
                    if ring.count > 2 { rings.append(ring) }
                    ring = []
                } else {
                    ring.append((Double(lon) / 100, Double(lat) / 100))
                }
            }
        }
        return rings
    }()
}
`)
