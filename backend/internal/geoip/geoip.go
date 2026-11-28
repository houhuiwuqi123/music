package geoip

import (
	"errors"
	"fmt"
	"math"
	"net"
	"strings"

	"github.com/lionsoul2014/ip2region/binding/golang/service"
	"github.com/lionsoul2014/ip2region/binding/golang/xdb"
	"github.com/oschwald/maxminddb-golang"
)

// Resolver turns a client IP into a display region and coarse coordinates. GeoLite2 covers the
// world and has coordinates; ip2region (optional) names Chinese provinces and cities far more
// reliably — GeoLite2 leaves many Chinese networks at just 中国 — but has no coordinates, so
// those come from cnPlaces.
type Resolver struct {
	db *maxminddb.Reader
	cn *service.Ip2Region
}

// Open loads the GeoLite2 MMDB (empty: none) and any ip2region xdb files (IPv4 and/or IPv6;
// the version is read from each file's header).
func Open(path string, xdbPaths ...string) (*Resolver, error) {
	r := &Resolver{}
	if path != "" {
		db, err := maxminddb.Open(path)
		if err != nil {
			return nil, fmt.Errorf("open GeoIP database: %w", err)
		}
		r.db = db
	}
	if len(xdbPaths) > 0 {
		cn, err := openIP2Region(xdbPaths)
		if err != nil {
			_ = r.Close()
			return nil, err
		}
		r.cn = cn
	}
	return r, nil
}

func openIP2Region(paths []string) (*service.Ip2Region, error) {
	var v4, v6 *service.Config
	for _, path := range paths {
		header, err := xdb.LoadHeaderFromFile(path)
		if err != nil {
			return nil, fmt.Errorf("open ip2region %s: %w", path, err)
		}
		version, err := xdb.VersionFromHeader(header)
		if err != nil {
			return nil, fmt.Errorf("ip2region %s: %w", path, err)
		}
		switch version.Id {
		case xdb.IPv4VersionNo:
			// ~11 MB: keep it all in memory (lock-free, no disk reads).
			v4, err = service.NewV4Config(service.BufferCache, path, 1)
		case xdb.IPv6VersionNo:
			// ~37 MB: keep only the vector index in memory, read the rest from disk.
			v6, err = service.NewV6Config(service.VIndexCache, path, 16)
		}
		if err != nil {
			return nil, fmt.Errorf("ip2region %s: %w", path, err)
		}
	}
	if v4 == nil && v6 == nil {
		return nil, errors.New("ip2region: no usable xdb file")
	}
	cn, err := service.NewIp2Region(v4, v6)
	if err != nil {
		return nil, fmt.Errorf("ip2region: %w", err)
	}
	return cn, nil
}

func (r *Resolver) Close() error {
	if r.cn != nil {
		r.cn.Close()
	}
	if r.db == nil {
		return nil
	}
	return r.db.Close()
}

// Region returns a display name for the client's location.
func (r *Resolver) Region(ip net.IP) (string, error) {
	region, _, err := r.Locate(ip)
	return region, err
}

type geoRecord struct {
	Location struct {
		Latitude  *float64 `maxminddb:"latitude"`
		Longitude *float64 `maxminddb:"longitude"`
	} `maxminddb:"location"`
	Country struct {
		IsoCode string            `maxminddb:"iso_code"`
		Names   map[string]string `maxminddb:"names"`
	} `maxminddb:"country"`
	Subdivisions []struct {
		IsoCode string            `maxminddb:"iso_code"`
		Names   map[string]string `maxminddb:"names"`
	} `maxminddb:"subdivisions"`
	City struct {
		Names map[string]string `maxminddb:"names"`
	} `maxminddb:"city"`
}

func (g *geoRecord) geo() []float64 {
	if lat, lon := g.Location.Latitude, g.Location.Longitude; lat != nil && lon != nil {
		return coarse(*lat, *lon)
	}
	return nil
}

func (g *geoRecord) subdivision() string {
	if len(g.Subdivisions) == 0 {
		return ""
	}
	return zhName(g.Subdivisions[0].Names)
}

// coarse rounds to 0.1° (~11 km): city level, never a street.
func coarse(lat, lon float64) []float64 {
	return []float64{math.Round(lat*10) / 10, math.Round(lon*10) / 10}
}

// Locate returns the display region plus coarse coordinates [lat, lon] rounded to 0.1°
// (city level), or nil when unknown.
func (r *Resolver) Locate(ip net.IP) (string, []float64, error) {
	if (r.db == nil && r.cn == nil) || ip == nil || ip.IsPrivate() || ip.IsLoopback() {
		return "地区未知", nil, nil
	}
	var record geoRecord
	if r.db != nil {
		if err := r.db.Lookup(ip, &record); err != nil {
			return "", nil, fmt.Errorf("GeoIP lookup: %w", err)
		}
	}
	if r.cn != nil {
		if region, geo, ok := r.locateCN(ip, &record); ok {
			return region, geo, nil
		}
	}
	if r.db == nil {
		return "地区未知", nil, nil
	}
	region := describe(record.Country.IsoCode, record.Country.Names, record.City.Names, record.Subdivisions)
	return region, record.geo(), nil
}

// locateCN answers for IPs ip2region places in China with at least a province ("中国|广东省|深圳市|移动|CN").
// Anything else (abroad, reserved, "中国|0|0") is left to GeoLite2.
func (r *Resolver) locateCN(ip net.IP, record *geoRecord) (string, []float64, bool) {
	value, err := r.cn.Search(ip.String())
	if err != nil {
		return "", nil, false
	}
	fields := strings.Split(value, "|")
	if len(fields) < 3 || fields[0] != "中国" {
		return "", nil, false
	}
	known := func(s string) string {
		if s = strings.TrimSpace(s); s == "0" {
			return ""
		}
		return s
	}
	province, city := trimCN(known(fields[1])), trimCN(known(fields[2]))
	if province == "" {
		return "", nil, false
	}
	sameProvince := record.Country.IsoCode != "" && sameName(record.subdivision(), province)
	if city == "" {
		// ip2region knows only the province; GeoLite2 may still know the city there.
		if glCity := trimCN(zhName(record.City.Names)); sameProvince && glCity != "" {
			return place(province, glCity), record.geo(), true
		}
		if at, ok := cnPlaces[province]; ok {
			return province, coarse(at[0], at[1]), true // the provincial capital
		}
		return province, record.geo(), true
	}
	if at, ok := cnPlaces[province+"|"+city]; ok {
		return place(province, city), coarse(at[0], at[1]), true
	}
	// A city added to ip2region after cnPlaces was generated.
	if sameProvince && sameName(zhName(record.City.Names), city) {
		return place(province, city), record.geo(), true
	}
	if at, ok := cnPlaces[province]; ok {
		return place(province, city), coarse(at[0], at[1]), true
	}
	return place(province, city), record.geo(), true
}

// place is "省份-城市" (广东-深圳); a city named like its province (北京, 天津) shows once.
func place(province, city string) string {
	if city == "" || city == province {
		return province
	}
	return province + "-" + city
}

// sameName compares Chinese place names ignoring 省 / 市 / 自治区 style suffixes
// (GeoLite2 "内蒙古自治区" vs ip2region "内蒙古").
func sameName(a, b string) bool {
	strip := func(s string) string {
		s = trimCN(s)
		for _, suffix := range []string{"壮族自治区", "回族自治区", "维吾尔自治区", "自治区"} {
			s = strings.TrimSuffix(s, suffix)
		}
		return s
	}
	return a != "" && strip(a) == strip(b)
}

func zhName(names map[string]string) string {
	if val := names["zh-CN"]; val != "" {
		return val
	}
	return names["en"]
}

func describe(isoCode string, country, city map[string]string, subdivisions []struct {
	IsoCode string            `maxminddb:"iso_code"`
	Names   map[string]string `maxminddb:"names"`
}) string {

	getName := zhName

	countryCode := strings.ToUpper(strings.TrimSpace(isoCode))
	countryName := getName(country)
	cityName := getName(city)

	var subName string
	if len(subdivisions) > 0 {
		subName = getName(subdivisions[0].Names)
	}

	// 1. 国内（中国）：精确到城市，“省份-城市”（如 广东-深圳）；直辖市只显示一次（北京）
	if countryCode == "CN" {
		province, city := trimCN(subName), trimCN(cityName)
		switch {
		case province != "" && city != "" && city != province:
			return province + "-" + city
		case province != "":
			return province
		case city != "":
			return city
		case countryName != "":
			return countryName
		}
		return "中国"
	}

	// 2. 国外：显示“国家-城市”
	if countryName != "" {
		detail := cityName
		if detail == "" {
			detail = subName
		}
		if detail != "" && detail != countryName {
			return countryName + "-" + detail
		}
		return countryName
	}

	// 兜底：若只有城市或省份
	if cityName != "" {
		return cityName
	}
	if subName != "" {
		return subName
	}

	return "地区未知"
}

// trimCN drops the 省 / 市 / 特别行政区 suffix GeoLite2 uses inconsistently ("广东" but "浙江省", "深圳市" but
// "杭州"), so names read alike and 北京市 / 北京 count as the same place.
func trimCN(name string) string {
	name = strings.TrimSpace(name)
	for _, suffix := range []string{"特别行政区", "省", "市"} {
		if trimmed := strings.TrimSuffix(name, suffix); trimmed != "" {
			name = trimmed
		}
	}
	return name
}

func ParseTrustedProxies(value string) ([]*net.IPNet, error) {
	proxies := []*net.IPNet{}
	if strings.TrimSpace(value) == "" {
		return proxies, nil
	}
	for _, item := range strings.Split(value, ",") {
		_, network, err := net.ParseCIDR(strings.TrimSpace(item))
		if err != nil {
			return nil, fmt.Errorf("invalid trusted proxy CIDR: %w", err)
		}
		proxies = append(proxies, network)
	}
	return proxies, nil
}

func ClientIP(remoteAddress, forwarded string, proxies []*net.IPNet) net.IP {
	host, _, err := net.SplitHostPort(remoteAddress)
	if err != nil {
		host = remoteAddress
	}
	ip := net.ParseIP(host)
	chain := strings.Split(forwarded, ",")
	for index := len(chain) - 1; index >= 0; index-- {
		trusted := false
		for _, network := range proxies {
			if network.Contains(ip) {
				trusted = true
				break
			}
		}
		if !trusted {
			break
		}
		next := net.ParseIP(strings.TrimSpace(chain[index]))
		if next == nil {
			break
		}
		ip = next
	}
	return ip
}

// cloudflare lists Cloudflare's edge ranges (https://www.cloudflare.com/ips/). A request whose
// nearest untrusted hop is one of these came through the Cloudflare proxy, which overwrites
// CF-Connecting-IP with the visitor's address, so that header is the real client.
var cloudflare = mustCIDRs(
	"173.245.48.0/20", "103.21.244.0/22", "103.22.200.0/22", "103.31.4.0/22", "141.101.64.0/18",
	"108.162.192.0/18", "190.93.240.0/20", "188.114.96.0/20", "197.234.240.0/22", "198.41.128.0/17",
	"162.158.0.0/15", "104.16.0.0/13", "104.24.0.0/14", "172.64.0.0/13", "131.0.72.0/22",
	"2400:cb00::/32", "2606:4700::/32", "2803:f800::/32", "2405:b500::/32", "2405:8100::/32",
	"2a06:98c0::/29", "2c0f:f248::/32",
)

func mustCIDRs(values ...string) []*net.IPNet {
	result := make([]*net.IPNet, 0, len(values))
	for _, value := range values {
		_, network, err := net.ParseCIDR(value)
		if err != nil {
			panic(err)
		}
		result = append(result, network)
	}
	return result
}

// IsCloudflare reports whether ip belongs to a Cloudflare edge range.
func IsCloudflare(ip net.IP) bool {
	for _, network := range cloudflare {
		if network.Contains(ip) {
			return true
		}
	}
	return false
}

// RequestIP is ClientIP plus Cloudflare: when the trusted proxy chain ends at a Cloudflare edge
// (nginx without real_ip forwards the edge address), the visitor is CF-Connecting-IP.
func RequestIP(remoteAddress, forwarded, cfConnecting string, proxies []*net.IPNet) net.IP {
	ip := ClientIP(remoteAddress, forwarded, proxies)
	if ip != nil && IsCloudflare(ip) {
		if visitor := net.ParseIP(strings.TrimSpace(cfConnecting)); visitor != nil {
			return visitor
		}
	}
	return ip
}
