package protocol

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestParseClient(t *testing.T) {
	cases := []struct {
		name    string
		raw     string
		wantErr bool
		check   func(*testing.T, *ClientMsg)
	}{
		{"join", `{"type":"join","room":"lobby","nick":"alice"}`, false, func(t *testing.T, m *ClientMsg) {
			if m.Kind != KindJoin || m.Join.Room != "lobby" || m.Join.Nick != "alice" {
				t.Fatalf("join 解析不符: %+v", m)
			}
		}},
		{"say", `{"type":"say","text":"你好","cid":"c-1"}`, false, func(t *testing.T, m *ClientMsg) {
			if m.Kind != KindSay || m.Say.Text != "你好" || m.Say.CID != "c-1" {
				t.Fatalf("say 解析不符: %+v", m)
			}
		}},
		{"say cid 缺省为空串", `{"type":"say","text":"x"}`, false, func(t *testing.T, m *ClientMsg) {
			if m.Say.CID != "" {
				t.Fatalf("cid 缺省应为空串: %+v", m)
			}
		}},
		{"say cid 非字符串忽略", `{"type":"say","text":"x","cid":42}`, false, func(t *testing.T, m *ClientMsg) {
			if m.Say.CID != "" {
				t.Fatalf("cid 非字符串应为空串: %+v", m)
			}
		}},
		{"leave", `{"type":"leave"}`, false, func(t *testing.T, m *ClientMsg) {
			if m.Kind != KindLeave {
				t.Fatalf("leave 解析不符: %+v", m)
			}
		}},
		{"ping", `{"type":"ping"}`, false, func(t *testing.T, m *ClientMsg) {
			if m.Kind != KindPing {
				t.Fatalf("ping 解析不符: %+v", m)
			}
		}},
		{"坏 JSON", `{"type":"broken`, true, nil},
		{"缺 type", `{}`, true, nil},
		{"join 缺 room", `{"type":"join","nick":"a"}`, true, nil},
		{"join 空串 room", `{"type":"join","room":"","nick":"a"}`, true, nil},
		{"say 缺 text", `{"type":"say"}`, true, nil},
		{"say 空 text", `{"type":"say","text":""}`, true, nil},
		{"未知类型", `{"type":"dance"}`, true, nil},
		{"非对象", `[1,2]`, true, nil},
		{"字符串", `"hello"`, true, nil},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			m, err := ParseClient([]byte(tc.raw))
			if tc.wantErr {
				if err == nil {
					t.Fatalf("期望报错，得到 %+v", m)
				}
				var pe *ParseError
				if !errorsAs(err, &pe) {
					t.Fatalf("错误类型应为 *ParseError: %T", err)
				}
				return
			}
			if err != nil {
				t.Fatalf("意外报错: %v", err)
			}
			if tc.check != nil {
				tc.check(t, m)
			}
		})
	}
}

func errorsAs(err error, target **ParseError) bool {
	pe, ok := err.(*ParseError)
	if ok {
		*target = pe
	}
	return ok
}

func TestWireShape(t *testing.T) {
	w := NewWelcome("lobby", "bob", []string{"alice", "bob"}, []ChatMessage{{ID: 1, From: "alice", Text: "hi", TS: 1700000000000}}, 1)
	b, _ := json.Marshal(w)
	got := map[string]any{}
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"type", "room", "you", "members", "last_id", "history"} {
		if _, ok := got[key]; !ok {
			t.Fatalf("welcome 缺字段 %s: %s", key, b)
		}
	}
	if got["last_id"].(float64) != 1 {
		t.Fatalf("last_id 应为 1: %s", b)
	}

	cases := []struct {
		name string
		raw  []byte
		keys []string
	}{
		{"chat", mustJSON(NewChat("lobby", 7, "alice", "hi", 123)), []string{"type", "room", "id", "from", "text", "ts"}},
		{"ack", mustJSON(NewAck("c-1", 7)), []string{"type", "cid", "id"}},
		{"joined", mustJSON(NewJoined("lobby", "bob", []string{"a"})), []string{"type", "room", "nick", "members"}},
		{"left", mustJSON(NewLeft("lobby", "a", nil)), []string{"type", "room", "nick", "members"}},
		{"error", mustJSON(NewError("nick_taken", "x")), []string{"type", "code", "message"}},
		{"pong", mustJSON(NewPong()), []string{"type"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := map[string]any{}
			if err := json.Unmarshal(tc.raw, &got); err != nil {
				t.Fatal(err)
			}
			for _, key := range tc.keys {
				if _, ok := got[key]; !ok {
					t.Fatalf("%s 缺字段 %s: %s", tc.name, key, tc.raw)
				}
			}
		})
	}
}

func TestUpstreamRoundTrip(t *testing.T) {
	m, err := ParseClient(JoinFrame("lobby", "alice"))
	if err != nil || m.Kind != KindJoin || m.Join.Room != "lobby" || m.Join.Nick != "alice" {
		t.Fatalf("joinFrame 往返不符: %+v err=%v", m, err)
	}
	m, err = ParseClient(SayFrame("你好", "c-9"))
	if err != nil || m.Kind != KindSay || m.Say.Text != "你好" || m.Say.CID != "c-9" {
		t.Fatalf("sayFrame 往返不符: %+v err=%v", m, err)
	}
}

func mustJSON(v any) []byte {
	b, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	if !strings.Contains(string(b), "{") {
		panic("非对象")
	}
	return b
}
