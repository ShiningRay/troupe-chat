# frozen_string_literal: true

# 端到端冒烟脚本：两个真实 WS 客户端连真实服务器，验证全链路后退出。
# 用法：bundle exec ruby smoke_e2e.rb <port>
require_relative "server/test/test_helper"

port = Integer(ARGV[0] || 7777)
a = TestClient.new(port)
b = TestClient.new(port)

a.join("lobby", "alice")
welcome = a.expect("welcome")
raise "welcome.you" unless welcome["you"] == "alice"
puts "[smoke] alice welcome: members=#{welcome['members'].inspect}"

b.join("lobby", "alice")
err = b.expect("error")
raise "nick_taken 期望, got #{err['code']}" unless err["code"] == "nick_taken"
puts "[smoke] 重名拒绝: #{err['code']}"

b.join("lobby", "bob")
b.expect("welcome")
joined = a.expect("joined")
raise "joined.members" unless joined["members"] == %w[alice bob]
puts "[smoke] bob 加入: members=#{joined['members'].inspect}"

a.send_text(JSON.generate({ "type" => "ping" }))
a.expect("pong")
puts "[smoke] ping→pong ok"

a.say("你好，Ruby 世界！中文\"引号\"测试", "cid-1")
ack = a.expect("ack")
raise "ack.cid" unless ack["cid"] == "cid-1"
id = ack["id"]
chat_a = a.expect("chat")
raise "chat echo" unless chat_a["id"] == id && chat_a["text"].include?("Ruby 世界")
chat_b = b.expect("chat")
raise "chat b" unless chat_b["id"] == id
puts "[smoke] say→ack(id=#{id})→双方广播 ok"

# 幂等重发
a.say("你好，Ruby 世界！中文\"引号\"测试", "cid-1")
ack2 = a.expect("ack")
raise "幂等 ack" unless ack2["id"] == id
puts "[smoke] 同 cid 重发 ack(id=#{ack2['id']}) ok"

b.close
left = a.expect("left")
raise "left.nick" unless left["nick"] == "bob"
puts "[smoke] 断线兜底 left(bob) ok"

a.close
puts "[smoke] 全链路通过 ✓"
