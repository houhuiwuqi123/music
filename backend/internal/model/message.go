package model

import "encoding/json"

// WSMessage 是客户端与信令服务器之间所有 WebSocket 消息的统一包装结构。
type WSMessage struct {
	Type      string          `json:"type"`
	File      *FileMeta       `json:"file,omitempty"`
	FileID    string          `json:"fileId,omitempty"`
	Files     []*FileMeta     `json:"files,omitempty"`
	To        string          `json:"to,omitempty"`
	From      string          `json:"from,omitempty"`
	Data      json.RawMessage `json:"data,omitempty"`
	Listening *Listening      `json:"listening,omitempty"`
	Listeners []Listening     `json:"listeners"`
	Error     string          `json:"error,omitempty"`
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
	ID        string `json:"id"`
	Name      string `json:"name"`
	Size      int64  `json:"size"`
	OwnerID   string `json:"ownerId"`
	OwnerName string `json:"ownerName"`
}
