package geoip

import (
	"fmt"
	"net"
	"strings"

	"github.com/oschwald/maxminddb-golang"
)

type Resolver struct{ db *maxminddb.Reader }

func Open(path string) (*Resolver, error) {
	if path == "" {
		return &Resolver{}, nil
	}
	db, err := maxminddb.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open GeoIP database: %w", err)
	}
	return &Resolver{db: db}, nil
}

func (r *Resolver) Close() error {
	if r.db == nil {
		return nil
	}
	return r.db.Close()
}

func (r *Resolver) Region(ip net.IP) (string, error) {
	if r.db == nil || ip == nil || ip.IsPrivate() || ip.IsLoopback() {
		return "地区未知", nil
	}
	var record struct {
		Country struct {
			Names map[string]string `maxminddb:"names"`
		} `maxminddb:"country"`
		Subdivisions []struct {
			Names map[string]string `maxminddb:"names"`
		} `maxminddb:"subdivisions"`
		City struct {
			Names map[string]string `maxminddb:"names"`
		} `maxminddb:"city"`
	}
	if err := r.db.Lookup(ip, &record); err != nil {
		return "", fmt.Errorf("GeoIP lookup: %w", err)
	}
	names := []map[string]string{record.Country.Names}
	for _, subdivision := range record.Subdivisions {
		names = append(names, subdivision.Names)
	}
	names = append(names, record.City.Names)
	parts := []string{}
	for _, name := range names {
		value := name["zh-CN"]
		if value == "" {
			value = name["en"]
		}
		if value != "" && (len(parts) == 0 || parts[len(parts)-1] != value) {
			parts = append(parts, value)
		}
	}
	if len(parts) == 0 {
		return "地区未知", nil
	}
	return strings.Join(parts, " · "), nil
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
