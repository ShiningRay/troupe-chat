# TroupeChat 客户端入口。
#
# 用法：
#   crystal run src/client.cr -- --server ws://127.0.0.1:7777 --nick alice
#   crystal build src/client.cr -o bin/chat_client.exe && bin/chat_client.exe
#
# 自动化验证：
#   --autotest            自动连接→发送 auto_send 文本→等待 ack（配合 --frames/--screenshot）
#   --frames=N            跑 N 帧后退出
#   --screenshot=path.png 出 PNG 截图

require "option_parser"
require "./sdl_host"

server = "ws://127.0.0.1:7777"
nick = ""
room = "lobby"
autotest = false
send_text = "hello from tessell"

OptionParser.parse(ARGV) do |p|
  p.banner = "TroupeChat client"
  p.on("-s URL", "--server=URL", "服务端 WebSocket 地址") { |v| server = v }
  p.on("-n NAME", "--nick=NAME", "昵称") { |v| nick = v }
  p.on("-r ROOM", "--room=ROOM", "房间名（默认 lobby）") { |v| room = v }
  p.on("--autotest", "自动化：连接→发消息→等 ack") { autotest = true }
  p.on("--send=TEXT", "autotest 发送的文本") { |v| send_text = v }
  p.on("-h", "--help", "帮助") do
    puts p
    puts "（--frames/--screenshot 直接传给窗口宿主）"
    exit 0
  end
  p.invalid_option { nil } # --frames/--screenshot 由宿主解析
end

app = ChatUI::ChatApp.new(server, nick, room)
app.autotest = autotest
app.auto_send_text = send_text

ChatHost::KitAppWindow.new(app).run(ARGV)
