# frozen_string_literal: true

# SQLite 重启恢复冒烟：phase=seed 写入数据；phase=verify 重启后校验恢复。
# 用法：bundle exec ruby smoke_restart.rb <port> <phase>
require_relative "server/test/test_helper"

port = Integer(ARGV[0] || 18077)
phase = ARGV[1] || "seed"

c = TestClient.new(port)
if phase == "seed"
  c.join("persist", "alice")
  c.expect("welcome")
  c.say("跨重启仍在", "cid-p")
  ack = c.expect("ack")
  raise "seed ack" unless ack["id"] == 1
  c.expect("chat")
  puts "[restart] 已写入：alice 发言 id=1；进程将被硬杀（模拟崩溃）"
else
  c.join("persist", "bob")
  welcome = c.expect("welcome")
  # alice 在 seed 阶段断线 → 网关兜底 leave（成员不跨重启保留是预期语义）；
  # 历史与消息号必须恢复且续接。
  raise "历史未恢复：#{welcome['history'].inspect}" unless welcome["history"].size == 1 && welcome["history"][0]["text"] == "跨重启仍在"
  raise "last_id 未续接" unless welcome["last_id"] == 1
  c.say("重启后的新消息", "cid-q")
  ack = c.expect("ack")
  raise "重启后 id 未续接：#{ack['id']}" unless ack["id"] == 2
  puts "[restart] 恢复校验通过：历史='跨重启仍在' last_id=1 新消息 id=#{ack['id']}"
end
c.close
