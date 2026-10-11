package model

import "encoding/json"

// WSMessage 是客户端与信令服务器之间所有 WebSocket 消息的统一包装结构。
type WSMessage struct {
	Type            string          `json:"type"`
	Mode            string          `json:"mode,omitempty"`
	File            *FileMeta       `json:"file,omitempty"`
	FileID          string          `json:"fileId,omitempty"`
	Files           []*FileMeta     `json:"files,omitempty"`
	To              string          `json:"to,omitempty"`
	From            string          `json:"from,omitempty"`
	Data            json.RawMessage `json:"data,omitempty"`
	Listening       *Listening      `json:"listening,omitempty"`
	Listeners       []Listening     `json:"listeners"`
	Error           string          `json:"error,omitempty"`
	RequestID       string          `json:"requestId,omitempty"`
	TransferID      string          `json:"transferId,omitempty"`
	Generation      int             `json:"generation,omitempty"`
	Transfer        *Transfer       `json:"transfer,omitempty"`
	ICEServers      []ICEServer     `json:"iceServers,omitempty"`
	GatewayEnabled  bool            `json:"gatewayEnabled"`
	ProtocolVersion int             `json:"protocolVersion,omitempty"`
}

type Listening struct {
	ClientID  string    `json:"clientId"`
	OwnerName string    `json:"ownerName"`
	Title     string    `json:"title"`
	Artist    string    `json:"artist"`
	IsPlaying bool      `json:"isPlaying"`
	Region    string    `json:"region"`
	File      *FileMeta `json:"file,omitempty"`
	Avatar    string    `json:"avatar,omitempty"`
	OfflineAt *int64    `json:"offlineAt,omitempty"`
}

// FileMeta 描述广场上发布的一个文件。
type FileMeta struct {
	ID              string `json:"id"`
	Name            string `json:"name"`
	Size            int64  `json:"size"`
	OwnerID         string `json:"ownerId"`
	OwnerName       string `json:"ownerName"`
	SHA256          string `json:"sha256,omitempty"`
	ProtocolVersion int    `json:"protocolVersion,omitempty"`
}

type Transfer struct {
	ID          string   `json:"id"`
	File        FileMeta `json:"file"`
	Mode        string   `json:"mode"`
	Token       string   `json:"token"`
	DownloadURL string   `json:"downloadURL,omitempty"`
	UploadURL   string   `json:"uploadURL,omitempty"`
	ExpiresAt   int64    `json:"expiresAt"`
	Status      string   `json:"status,omitempty"`
	Generation  int      `json:"generation,omitempty"`
}

type ICEServer struct {
	URLs       []string `json:"urls"`
	Username   string   `json:"username,omitempty"`
	Credential string   `json:"credential,omitempty"`
}
