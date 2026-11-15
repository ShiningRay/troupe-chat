# TroupeChat 服务端入口。
#
# 用法：
#   crystal run src/server.cr -- -p 7777 -d chat.db
#   crystal build src/server.cr -o bin/chat_server && bin/chat_server -p 7777
#
# - SQLite 持久化（WAL）：房间成员/最近消息随 Turn 原子提交，重启即恢复；
# - -d :memory: 走内存 Provider（测试/临时演示）；
# - --metrics-port 开启 troupe Director 健康与指标端点（/health /metrics /events）。

require "option_parser"
require "./chat/gateway"

module Chat
  def self.run(argv : Array(String)) : {Troupe::Stage, Gateway}
    host = "127.0.0.1"
    port = 7777
    db = "chat.db"
    metrics_port = 0

    OptionParser.parse(argv) do |p|
      p.banner = "TroupeChat server"
      p.on("-H HOST", "--host=HOST", "监听地址（默认 127.0.0.1）") { |v| host = v }
      p.on("-p PORT", "--port=PORT", "WebSocket 端口（默认 7777）") { |v| port = v.to_i }
      p.on("-d PATH", "--db=PATH", "SQLite 路径或 :memory:（默认 chat.db）") { |v| db = v }
      p.on("-m PORT", "--metrics-port=PORT", "健康/指标端点端口（0 关闭，默认 0）") { |v| metrics_port = v.to_i }
      p.on("-h", "--help", "帮助") do
        puts p
        exit 0
      end
      p.invalid_option { |arg| abort "未知参数：#{arg}" }
    end

    store = db == ":memory:" ? Troupe::MemoryPropStore.new(Troupe::MemoryOwnershipStore.new) : Troupe::SQLitePropStore.open(db)
    stage = Troupe::Stage.new(store: store, ownership: store.ownership)
    stage.register(RoomActor.troupe_manifest)

    gateway = Gateway.new(stage, store)
    actual = gateway.listen(host, port)
    puts "TroupeChat server: ws://#{host}:#{actual}/  db=#{db}"

    if metrics_port > 0
      director = Troupe::Director.new
      director.add_stage("chat", stage)
      endpoint = Troupe::HTTPEndpoint.new(director, host, metrics_port)
      puts "metrics: http://#{host}:#{endpoint.listen}/health"
    end

    {stage, gateway}
  end
end

Chat.run(ARGV)
sleep # HTTP/WS 与 outbox 投递均在后台纤程，主纤程常驻
